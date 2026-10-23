# Round 23 handoff: Phases 0 to 7b done; Phase 7 review fixes and Phase 8 to do

This file is self-contained. A new session (another Claude account) can continue from it alone, together with:
- the repository `tejasrao97/tpg-poc`, branch `claude/implementation-plan-clarify-6emw16`, open pull request
  https://github.com/tejasrao97/tpg-poc/pull/1 (opened by the user from the UI; no CI configured; the user merges);
- the original plan `ROUND23-PLAN.md` (upload it again in the new session; its "Locked decisions" are final except
  where this file records a later user decision).

State on 2026-10-13: head `44d0b08`, clean tree, everything pushed. 47 commits on top of base `3d7d58a` (the plan's
V16; the branch is V17). The plan's `/Users/tejas/Downloads/...` paths and Homebrew step do not apply: there are no
V16/V17 folders and no per-repository git; the one repository holds `tpg-fleet/`, `tpg-aks-infra/` and, at its root,
`HANDOFF.md`, `workflow-commands.md`, `monitoring.md`, `README-manual-steps.md` and the two `.docx`.

How the user works (keep it): before each step, ask clarifying questions with the AskUserQuestion tool, summarize,
and wait for "go". Report briefly after each push. Keep this handoff out of git (Phase 8 folds it into `HANDOFF.md`).

---

## 0. What to do next (in order)

1. Recreate the environment (section 5) and run the full gate once on `44d0b08` to get a baseline. The last commit is
   an ungated work-in-progress commit (section 3.1); expect `tests/params` to be the suite to watch.
2. Finish the Phase 7 review fixes (section 3), gate, commit `Round 23 phase 7 review fixes: ...` on top (no history
   rewrite: everything is pushed), push. Phase 7 is then done (the user decided: one Opus review for Phase 7, a
   re-review only for blocking findings; the review found nothing blocking).
3. Phase 8 (section 4): ask the user the open Phase 8 questions first (section 4.1), then execute.
4. Final report and PR #1 title/description (section 4, step 7; section 6).

---

## 1. What is done

| Phase | Commits | What it delivered |
|---|---|---|
| 0 Baseline | `7ba2b34` | The V16 suites had never run with real yq, helm, shellcheck and tofu. Fixed tool-dependent test expectations, regenerated stale clusterMap examples, trimmed stale unused-keys allow-list entries, shellcheck notes, `tofu fmt`. No behaviour change. |
| 4 disableInitialBackup (run before 1) | `486ef20`, `e15017f` | Duplicate keys in `cluster-map-keys.yaml` sent clusterMap `disableInitialBackup` to `backup.enableSSL`; fixed, `backupEnableSSL` wired, duplicate-key check over `workflows/params`, chart default false, chart tests through the real ApplicationSet values. |
| 1 Folder move | `c0b3283`, `679e336` | `helm_artifacts/instance/{tpg-instance,crd-reference}`, `helm_artifacts/operator/{overlays,patches}`; every path reference rewritten; drift test ApplicationSet vs scripts. tpg-aks-infra unchanged. |
| 2 Strict lists | `2d783bd`, `e6aa19b` | One parser (`clustermap.py as_list`, shell `list_items`); bracketed lists only (`all`/`auto` bare); whitespace / map file entries get `repo:<file path> "check for white spaces in between"`; admission CEL patterns; submit scripts send the bracketed form; YAML sequences accepted in parameter files (argo 4.1.3 verified). |
| 3 Namespace key | `c4cb73d`, `6bd95c0`, `e4134e4` | `namespace` key (default `pg-<instance>`, immutable, reserved list + `kube-*`); `instance_ns` accessor; shared namespaces with one owner (`sharedSecretsOwner`) and hand-over on delete by selective Argo sync; per-instance network policies; NAMESPACE_SECRET_CONFLICT; delete guards. |
| 5 Purge and expire | `8b41c4b`, `ae4c38a`, `6c1d630` | `purgeBackups` on tpg-delete-instance / tpg-delete-apps; new `tpg-backup-expire` (clusterMap only, dryRun default true); fail-closed shared-repo check; expire-state freshness. |
| 6 Restore by clusterMap pairs | `4426a18`..`6b5761a` (6a, 6a follow-up, 6b, three 6b revisions, 6c, review fixes) | Section 2. Opus review: nothing blocking; all findings fixed in `6b5761a`. |
| 7a Parameter-file schemas | `567d33e` | `workflows/params/params_schema.py` (`--check`, wired into `validate.sh`): per workflow W (template name without `tpg-`; 13 workflows) `schemas/params-W.schema.{json,yaml}` and `params-W.example.yaml` (= worked example 1), and a generated block after each workflow's input table in `docs/workflow-commands.md` (`<!-- BEGIN/END GENERATED: params-W -->`; found by section title). `types.yaml` gains `mandatory: always|conditional`. `tests/params` rewritten (schema + real `argo submit` against envtest admission + offline validate step; doc examples bound to their submit commands; input tables checked for Type, Mandatory, Default, enums). |
| 7b Docs | `e87aa10`, `a23f57f`, `6e952dc`, `db7ed6d`, `0813982` | `workflow-commands.md` restructured and renumbered (section 1.1 below), section 16 restore rebuilt with a reason-code table enforced by `tests/restore` section 9, two worked examples per workflow, READMEs of both repositories. |
| 7 review fixes | `44d0b08` (WIP, ungated) | Fix 1 of 12 started (section 3.1). |

Last full green gate: on `0813982` (7b). Counts then: restore 450, params 346, cluster-map 329, restore-map 230,
admission 184, delete 145, chart 137, day0-plan 104, patch 90, backup-expire 75, submit 63, crd-reference 33,
scale 30, shared-lib 27, rollout 23, sync-engine 21, waits 18, git-merge 17, network-policy 17, monitoring 16,
pgdata 16, rotate 15, helm4 12, stuck-app 8, regex-limits 5, unused-keys 4; tpg-aks-infra: deploy-scripts 104,
jumpbox 85 (tofu validate/test SKIP), verify 48, vault-secret 31, shared-lib 27, argocd-rbac 24, preflight 6.
`validate.sh` rc=0 ("All checks passed"; it runs `tests/run-all.sh`, "All test suites passed"); every generator
`--check` clean; `argo lint --offline tpg-fleet/workflows/templates/` clean. The `cli-flags` summary line prints a
"fix:" message: that is its self-test planting violations, fine at rc=0.

### 1.1 Section numbering of `tpg-fleet/docs/workflow-commands.md` (after 7b)
1 Set up the CLIs · 2 Input types and conventions · 3 clusterMap · 4 tpg-day0 · 5 tpg-create-instance · 6 tpg-upgrade ·
7 tpg-patch · 8 tpg-scale-instance · 9 tpg-network-policy · 10 tpg-delete-apps · 11 tpg-delete-instance ·
12 tpg-helm-addons · 13 tpg-backup · 14 tpg-backup-expire (moved from 21) · 15 CA bundles and credential values in
Vault · 16 tpg-restore · 17 tpg-rotate-credential · 18 Interactive submit scripts · 19 pgdata · 20 Follow, approve,
stop and clean up runs · 21 argocd CLI. Every "section N" reference in both repositories was renumbered and verified.

### 1.2 Rules 7a introduced that later work must keep
- Doc-example binding (header of `tpg-fleet/tests/params/check_param_files.py`): a parameter file in the docs is a
  ```` ```yaml ```` fence whose first line is `# NAME.yaml`, or a `cat > NAME.yaml <<'TAG'` heredoc in a bash fence;
  it binds to `argo submit --from workflowtemplate/W --parameter-file NAME.yaml [-p ...]`. Every defined file must be
  submitted and every submitted file defined.
- Generated blocks, schemas and examples are never hand-edited: run `python3 workflows/params/params_schema.py`.
- `clustermap_schema.py` leaves `params-*` files in `schemas/` alone.

---

## 2. Phase 6: the restore as built (current truth; replaces the plan's decision 7 where they differ)

Inputs (`tpg-restore`): `clusterMap` (list of pairs), `rolloutMode`, `pushMode`, `dryRun` (default "true"),
`maxParallel`, `restoreTimeoutSeconds`, `prTimeoutSeconds`, `patchFiles`, `keepSourceLocation` (default "true").
Flat restore inputs and Phase 2's `cluster_one` are gone; the old `restore.sh` is removed.

Pairs: `[{sourceClusterConfig: {<c>: {<ns>: {<instance>: {...}}}}, targetClusterConfig: {...}}]`, validated and
normalized by `clustermap.py restore`. Methods: new cluster; same cluster other namespace (or a new instance in the
source namespace); in place. One target per run; a target cannot be another pair's source. Batching by
`plan-batches.sh` with a canary; mutex per target instance and per target cluster+namespace.

| Restore key | CRD field |
|---|---|
| `sourceBackupName` (`pitrEnabled: false`, the default) | `postgresrestore.spec.sourceBackup.name` |
| `pitrConfig.type` (latest/time/lsn/transaction) | `postgresrestore.spec.pitr.type` |
| `pitrConfig.target` (lsn, transaction) | `postgresrestore.spec.pitr.target` |
| `pitrConfig.timestamp` (time) | `postgresrestore.spec.pitr.timestamp` |
| `bestEffort` | `postgresrestore.spec.pitr.bestEffort` |
| `srcBackupLocationName` | `postgresrestore.spec.pitr.sourceBackupLocation.name` |
| `srcStanzaName` | `postgresrestore.spec.pitr.sourceBackupLocation.stanzaName` |
| `srcBackupLabel` | `postgresrestore.spec.pitr.sourceBackupLocation.set` |
| target instance / spec file | `postgresrestore.spec.targetInstance.name` / `.spec` |

Rules (`workflows/scripts/restore-pair.sh`, `validate-params.sh` restore mode):
- Per-pair order (code): plan checks and render → dryRun stops here → for a new target: push the fleet entry, create
  the namespace, sync the shared objects and backup location → copy the source location and its Secret → backupSync
  wait → apply the PostgresRestore → wait → Running → restore-patch record or live snapshot → adoption sync →
  optional post-restore backup → optional location removal.
- Named backups work into every target. Same namespace: the PostgresBackup must exist and be Succeeded at plan time
  (BACKUP_NOT_FOUND / BACKUP_NOT_SUCCEEDED). Other namespace/cluster: the source backup must be Succeeded
  (SOURCE_BACKUP_UNVERIFIED / BACKUP_NOT_SUCCEEDED), then after the location copy the synced PostgresBackup of the same
  name must reach Succeeded within `restoreTimeoutSeconds` (BACKUPS_NOT_SYNCED; Failed stops at once).
  BACKUP_OF_OTHER_INSTANCE refuses a backup of another instance.
- Location copy `restore-src-<cluster>-<ns>-<instance>` with its own Secret `<copy>-creds` (values copied in memory
  only: never a file, the log or argv); an existing copy for the same repository is reused (backupSync required, else
  SOURCE_LOCATION_CONFLICT); SOURCE_SECRET_CONFLICT when a reused copy's Secret has other contents from another source;
  an unreadable location list fails TARGET_UNREADABLE. `keepSourceLocation=false` removes only a copy this run created
  (with its Secret) and keeps it with SOURCE_LOCATION_IN_USE when any Postgres in the namespace references it
  (SOURCE_LOCATION_NOT_REMOVED when that list is unreadable).
- Version matrix: RESTORE_VERSION_LOWER and RESTORE_FLAVOUR_UNSUPPORTED always block the pair (versions parsed with
  `ver_of`, three-part dbVersion safe); `skipMinorVersionCheck` only sets the operator annotation (for backups from
  operator 4.2.2 or older). The major check is the operator's.
- Targets: TARGET_EXISTS for a live instance that is neither the source nor in place (plan time, also dryRun). A target
  declared in fleet.yaml but not deployed is a new target and its entry is replaced (SPEC_FILE_REQUIRED when the
  source is not in fleet.yaml and no spec file is given; the user confirmed this refusal). In place needs
  `clusters.<c>.cluster.allowInPlaceRestore: true` (else IN_PLACE_NOT_ALLOWED refuses the whole run in the validate
  step) and `confirm` when dryRun=false (missing: the validate step refuses the whole run); `confirm` on any other
  pair is refused.
- Spec file `targetInstanceSpecFilePath` (repo files only under `helm_artifacts/instance/tpg-instance/restore-specs/`,
  no symlinks: SPEC_FILE_INVALID; local files via `patchFiles`) becomes `targetInstance.spec`; allowed for new targets
  and in place. The copy's fixed name is accepted as its `backupLocation` when this run creates or reuses the copy.
  Without a spec file the PostgresRestore carries only the name and the operator fills the spec (lab item).
- dryRun is read-only for every pair. POST_RESTORE_BACKUP_FAILED is a warning; the pair stays SUCCEEDED.
- Restore-patch: `instance.restored: true` and `instance.restorePatch.{current, previous, mode: base|over, postgresPatch}`
  in the entry; files in `helm_artifacts/instance/tpg-instance/restore-patch/`. Base mode (new target, or in place
  without a spec file): the render starts from the restore-patch with no chart defaults; the restore-patch's
  `backupLocation`/`imagePullSecret` win, fleet values fill in only where it omits them. Over mode (in place with a
  spec file): the existing render with the restore-patch over it. Without a spec file the live CR is snapshotted
  (strict schema; RESTORE_PATCH_NOT_RECORDED names the unknown fields). The entry is seeded from the restore-patch.
- Later changes to a restored CR only from tpg-scale-instance, tpg-upgrade (postgres) and tpg-patch (patch files,
  applied over the restore-patch); a values patch setting `instance:` keys is BLOCKED PATCH_REFUSED with
  RESTORED_VALUES_PATCH in the detail (both modes). tpg-day0 / tpg-create-instance: BLOCKED INSTANCE_RESTORED for that
  instance only; discover.sh excludes restored instances. tpg-network-policy stays allowed.
- Submit: `scripts/submit/tpg-restore.sh` is a guided pair builder plus load-file/paste; each pair checked with
  `clustermap.py restore` and its plan printed before submit; hub and repo only (no member-cluster kubectl); offers
  `restore-specs/` files and local files.

---

## 3. Open: Phase 7 review fixes (review of `6b5761a..0813982`; nothing blocking)

Do all twelve, tests first where a behaviour changes, never weaken an assertion, regenerate generated files with
`params_schema.py`. One commit on top: `Round 23 phase 7 review fixes: mandatory inputs never empty in schemas,
restore step order, docs accuracy`. Paths below are under `tpg-fleet/`; line numbers are from `0813982`.

### 3.1 Status of the work-in-progress commit `44d0b08` (ungated)
Done there for fix 1: `params_schema.py` `value_schema` drops the empty alternative when `mandatory == "always"`
(`empty = bool(spec.get("allowEmpty")) and spec.get("mandatory") != "always"`); the 13 schemas regenerated;
`types.yaml` header comment updated; `tests/params/check_param_files.py` new check 6 `never_empty` (for every
`mandatory: always` input: the schema refuses "", the admission policy still accepts it through allowEmpty, the
validate step refuses it) and the VALUES table row `("tpg-day0", "pushMode", "", True)` removed (it asserted the old
behaviour; this is the deliberate behaviour change, say so in the commit body). NOT yet done: running `tests/params`
and the gate on it; confirm `params_schema.py --check` is clean and the generated docs blocks/examples are unaffected.

### 3.2 The twelve findings
Should-fix:
1. `workflows/params/params_schema.py` (~197, 199, 233-234; `required` ~250): inputs with `allowEmpty: true` and
   `mandatory: always` accepted "" (pushMode of day0, create-instance, upgrade, patch, scale-instance,
   network-policy, delete-apps; confirm of delete-instance, delete-apps; clusterMap of restore, backup-expire;
   clusters of helm-addons; mode of network-policy). Reproduced with real argo + envtest. Status: section 3.1.
2. `docs/workflow-commands.md` ~2329-2332 (section 16 per-pair steps): the doc ordered copy → sync wait → render →
   push/apply; the code (`restore-pair.sh` headers ~640, 686, 721, 778, 874) does the order in section 2 above. Renumber
   to the code and say that the entry, namespace and Application already exist after SOURCE_LOCATION_FAILED,
   NO_VAULT_SECRET or BACKUPS_NOT_SYNCED (and what to do: re-run the pair, or delete the target).
3. `docs/workflow-commands.md:81` (section 2, `String (name)` row) names `backupName`, a removed flat restore input.
   Name the inputs that use the type now (verify in `types.yaml`; e.g. `storageClass`, `secretName`,
   `backupCaBundleVaultSecret`, `ferretSecretName`, `ferretReadOnlySecretName`). Grep docs/READMEs for any other removed
   restore input (see `git show 495a6db -- tpg-fleet/workflows/params/types.yaml`).

Nits:
4. `types.yaml:134` day0 `patchFiles` → `mandatory: conditional`, docs cell (~519) like create-instance ("with a local
   file"; `patch_files_check` requires it). tpg-patch `backupCaBundleFile`/`backupCaBundleVaultSecret`: verify in
   `validate-params.sh` whether they belong to the "one of" group of the conditional path inputs; if so, conditional.
5. `docs:94`: the corrected-form hint ("Did you mean [a, b]?") is printed only for a comma string and a bare name;
   `[]`, `[a, , b]` and nested lists get their own messages (quote them from `clustermap.py`).
6. `docs:136`: argo 4.1.3 turns unquoted `yes`/`no`/`on`/`off` into "true"/"false", so the run accepts them; the
   schema (YAML 1.2, check-jsonschema) refuses them. Reword ("the schema refuses yes/no/on/off; write true/false").
   The other claims there were verified (17.10 → 17.1, 1.0 → 1, a sequence → its JSON text).
7. `tests/params`: the 13 doc examples that name local files skip the validate step. Run them through it and accept
   only the "contents are not in patchFiles" error(s) (the reviewer did this: only that error appears; their script is
   gone with the old container). Then make docs:130, `tests/README.md` and `README.md` wording exactly true.
8. `params_schema.py` `put_block`: check each block's markers sit inside the section of its own workflow
   (`## N. tpg-W` up to the next `## `); `--check` must fail otherwise. Add a mutation test like the existing self-tests.
9. tpg-delete-instance worked example 1 (`params-delete-instance.example.yaml`, `confirm: [orders-db]`) is a real
   confirmed delete. Add a warning line to the generated example's comment header and to the doc text before it (prefer
   a dry-run-like option if the template has one; verify).
10. `docs:2265` (section 16 in-place row) "Either missing refuses the pair": a missing `confirm` with dryRun=false
    fails the validate step and refuses the whole run; missing `allowInPlaceRestore` refuses the whole run too.
11. `tpg-fleet/README.md`: V14 runs `tpg-backup -p dryRun=true` but tpg-backup has no dryRun input (admission refuses
    it; pre-existing): fix the command; restore summary (~363) misses "a new instance in the source namespace"; the
    claim "two worked examples: a dry run on one cluster and several clusters with a clusterMap" is not true for
    workflows without dryRun or clusterMap: reword; V47/V54 `kubectl -n pg-<instance>`: add that it is the instance's
    namespace (default `pg-<instance>`, `namespace` key).
12. docs section 14 (tpg-backup-expire) results list misses EXPIRE_FAILED, BACKUPS_UNREADABLE, NOT_REGISTERED,
    FLEET_UNREADABLE (recorded by `backup-expire.sh`; present in the section 20 table). Make it complete; optionally a
    both-directions table test like `tests/restore` section 9.

Reviewer confirmed correct (no need to re-check): generator drift detection (doc block, schema json/yaml, example,
extra/missing file, removed block), schema keys = template parameters, `required` = `mandatory: always`, `mandatory:`
values per input (apart from 4 and 1), every tests/params check can fail, section 16 content apart from 2 and 10,
purgeBackups rules, namespace rules, carry items, renumbering, no old folder paths / comma lists / restore.sh leftovers,
tpg-aks-infra docs vs `60-verify.sh`, monitoring labels.

---

## 4. Open: Phase 8 (documents, zips, final review)

### 4.1 Ask the user first (not yet decided)
- The `.docx` content scope: how much per label range (one row/paragraph per decision vs. a section per feature), and
  whether the Runbook tests T146+ cover only Round 23 features or also re-verify affected older tests.
- Whether `HANDOFF.md` gets this whole file's content or a condensed Round 23 section plus lab items.
- Zips: confirm names (`tpg-fleet.zip`, `tpg-aks-infra.zip`), contents (repository folders without `.git`; root docs
  and `.docx` included or separate) and that they are sent as files only (decided: not committed).
- Final report shape (in chat vs. a published page).
Decided already: `.docx` edited in place with python-docx in each document's existing styles; labels continue at
D95+ (POV Design decisions), V108+ (POV lab items), V86+ (README items), T146+ (Runbook tests); one Opus review of
Phase 8 plus a final whole-round review; at the end the PR #1 title/description are rewritten and the user merges.

### 4.2 Steps
1. Root copies `workflow-commands.md`, `monitoring.md`, `README-manual-steps.md` made identical to
   `tpg-fleet/docs/workflow-commands.md`, `tpg-fleet/docs/monitoring.md`, `tpg-aks-infra/docs/README-manual-steps.md`
   (check how earlier rounds kept them in step; a test may compare them).
2. `Tanzu-Postgres-AKS-POV-Design.docx` and `Tanzu-Postgres-AKS-POC-Runbook.docx` (repository root) edited in place
   with python-docx in their existing styles: decisions D95+, POV lab items V108+, README items V86+, Runbook tests
   T146+ (restore methods, expire, purge, namespace, strict lists, parameter files, lab-only items in section 6).
   Read the last labels in each document first and continue from them.
3. `HANDOFF.md` (root): Round 23 section (content of this file), next labels, open lab items.
4. Zips `tpg-fleet.zip`, `tpg-aks-infra.zip` (no `.git`) in the session's scratch folder; unzip into a fresh folder
   and run `tests/run-all.sh` there; send the zips to the user as files (not committed).
5. Gate, commit `Round 23 phase 8: documents and handoff`, push; one Opus review of Phase 8; fixes.
6. Final whole-round review of `git diff 3d7d58a..HEAD` against the plan and the decisions; leftovers search (comma
   lists, derived `pg-<instance>`, old folder paths, removed restore inputs); fixes.
7. Rewrite PR #1 title and description for the whole round (GitHub MCP tool `update_pull_request`; description ends
   with the session's attribution lines); final report to the user (section 6).

---

## 5. Environment, gates and conventions (recreate in the new session)

### 5.1 Toolchain
Install with the repository's own `tpg-aks-infra/scripts/jumpbox/setup-jumpbox.sh --only run-time,tests` (pinned,
sha256-checked). Tools: mikefarah yq 4.47.2, helm 4.3.0, shellcheck 0.10.0, yamllint 1.38.0, kubeconform 0.7.0,
kustomize 5.7.1, argo 4.1.3, argocd 3.5.3, tofu 1.9.1, promtool 3.5.0, kubectl 1.35.8, envtest 1.34.1, jq 1.7,
PostgreSQL 16 server binaries. Workarounds needed in the cloud container last time:
- `get.helm.sh` blocked: `go install helm.sh/helm/v4/cmd/helm@v4.3.0`, copy to `/usr/local/bin`, then
  `echo 4.3.0 > /var/lib/tpg-jumpbox/helm.version`.
- yamllint: the script pins cp312 wheel hashes; put a Python 3.12 shim first on PATH (the image's python3 was 3.13).
- promtool 3.5.0 from the Prometheus GitHub release (sha256-checked).
- `apt-get install postgresql` for the pgdata suite.
- A venv with PyYAML, python-docx, check-jsonschema, jsonschema, cryptography, psycopg[binary], first on PATH.
- `registry.opentofu.org` / `registry.terraform.io` blocked: jumpbox `tofu validate`/`tofu test` SKIP (expected).

### 5.2 Helper scripts (recreate in the scratch folder `$S`)
`env.sh`:
```bash
export PATH="$S/venv/bin:/usr/local/bin:$PATH"
export KUBEBUILDER_ASSETS=/usr/local/lib/tpg-envtest/k8s/1.34.1-linux-amd64
```
`run-each.sh LOGFILE` (every suite separately plus validate.sh; one summary line per suite; set F and I to the clone):
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"
F=<clone>/tpg-fleet; I=<clone>/tpg-aks-infra; OUT="${1:-/dev/null}"; : > "$OUT"
run() { local name="$1"; shift; local log rc; log="$("$@" 2>&1)"; rc=$?; printf '\n=== %s (rc=%s)\n%s\n' "$name" "$rc" "$log" >> "$OUT"
  local sum; sum="$(printf '%s\n' "$log" | grep -E '[0-9]+ passed|SKIP|passed,|failed' | tail -1)"; printf '%-28s rc=%-3s %s\n' "$name" "$rc" "$sum"; }
run cli-flags bash $F/tests/cli-flags/run.sh
for s in regex-limits waits git-merge stuck-app helm4 shared-lib sync-engine rollout params cluster-map restore-map restore scale patch chart crd-reference day0-plan network-policy delete backup-expire submit rotate pgdata admission monitoring unused-keys; do run "$s" bash $F/tests/$s/run.sh; done
[[ -d $F/tests/envtest && -f $F/tests/envtest/run.sh ]] && run envtest bash $F/tests/envtest/run.sh
FLEET_LOCAL_DIR=$F run infra/verify bash $I/tests/verify/run.sh
for s in preflight argocd-rbac jumpbox deploy-scripts vault-secret shared-lib; do [[ -f $I/tests/$s/run.sh ]] && run "infra/$s" bash $I/tests/$s/run.sh; done
(cd $F && run validate.sh bash scripts/validate.sh)
```

### 5.3 Gate (every step, before committing)
1. `run-each.sh` all rc=0; `validate.sh` rc=0 (it runs `tests/run-all.sh`, ending "All test suites passed").
2. Generators with `--check`: `workflows/params/generate.py`, `clustermap_schema.py`, `patch_schemas.py`,
   `params_schema.py`, `tools/crd-defaults/generate.py`, `monitoring/grafana/generate.py`.
3. `argo lint --offline tpg-fleet/workflows/templates/`; shellcheck and yamllint clean as validate.sh runs them (no new
   `# shellcheck disable` without a reason comment on the same line).
4. Re-read the diff adversarially.
The full gate takes 25 to 40 minutes (`tests/restore` about 3 minutes, `tests/params` about 1.5 minutes, the
shellcheck step about 2.5 minutes). NEVER run two gate runs (run-each, run-all, validate.sh) at the same time: suites
share fixed temp files and envtest ports and fail spuriously. Use long Bash timeouts or background runs.

### 5.4 Conventions
- Match the surrounding code: comment density, naming, the `ok`/`bad` test idiom, record/result codes, `log`/`die`,
  messages that name the input and the fix.
- Tests first; never weaken, skip or delete an assertion to get green (a deliberate behaviour change updates the
  assertion and is named in the commit body). Regenerate generated files with their generator.
- Commit on top (everything is pushed; no rebase, amend, squash or force-push). Work-in-progress commits during long
  steps, pushed, so a container restart or usage limit loses nothing.
- Commit trailer: the new session's own attribution lines (the earlier commits used
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and a `Claude-Session:` URL). No model names in files or
  commit text otherwise. Only push to `claude/implementation-plan-clarify-6emw16`; do not open another PR.
- Secrets: never in files, logs or argv (restore copies Secret values in memory only).
- Execution model the user approved: implementation by subagents, one Opus review per phase (a re-review only for
  blocking findings); on a usage-limit cut-off back up the work in progress, resume at reset, tell the user briefly.

---

## 6. For the final report (tell the user)

- Pre-existing, outside the plan: `tpg-delete-apps` removing the operator leaves
  `helm_artifacts/operator/{patches,overlays}/clusters/<c>.yaml` behind (a stale patch copy could reach a reinstalled
  operator). Not fixed; suggested follow-up. Also pre-existing: README V14 used `tpg-backup -p dryRun=true` (fix 11).
- Phase 5: `purgeBackups` on a non-running instance purges its own repoPath without an expire; a shared one fails
  BACKUP_EXPIRE_IMPOSSIBLE. In tpg-delete-apps, two run instances sharing one pinned repoPath: the second deletes the
  blobs.
- Lab items (to state in the Runbook as tests, not facts): operator expire signalling (observedGeneration /
  lastTransitionTime), pgBackRest last-full refusal, real Azure SharedKey acceptance, Argo CD selective sync and
  terminate-op in the owner hand-over, the `postgres-instance` and `app=ferretdb-*` pod labels, PVC labels for a
  shared-namespace purge, live Prometheus joins, Cilium selectors; restore: how the operator fills
  `targetInstance.spec` without a spec file, `skip-minor-version-check`, `-lite` naming, the operator's in-place spec
  merge, the live snapshot passing the closed schema, the Argo canary stop at runtime.
- Lists: only whitespace and `repo: path` map entries get the `"check for white spaces in between"` message; other
  malformed paths keep their specific messages (the reading of locked decision 2).
- Parameter files: argo 4.1.3 reads them as YAML 1.1; the schemas refuse unquoted versions/decimals and null, and
  `clusterMap` must be a block string (user decisions).
- Commit trailers: the 6b third-revision commits (`ee5aaa2`..`43b021d`) carry a different attribution line from the
  rest; left as is (pushed history).

---

## 7. All user decisions (beyond the plan), for reference

Execution: work in place on the branch, push per phase; Phase 0 baseline fix commit; Phase 4 before Phase 1; no PR by
Claude (the user opened #1); zips as files only; this handoff out of git; `.docx` edited in place (D95+, V108+, V86+,
T146+); PR #1 rewritten at the end, the user merges.

Phase 3: old `tpg-ingress`/`tpg-egress` policies fresh deploy only (documented); a foreign `regsecret`/`backup-storage`
blocks (NAMESPACE_SECRET_CONFLICT); reserved namespaces = decision-8 list + operator + fleet infra namespaces
(`vault-secrets-operator-system`, `tpg-vault`) + `kube-*`.

Phase 6 (all reflected in section 2): named backups supported everywhere, `spec.sourceBackup.name`; PostgresBackup
checks (Succeeded at plan time same namespace; source Succeeded then synced copy Succeeded within
restoreTimeoutSeconds elsewhere); reuse of an existing location copy; dryRun read-only and default true; pitrEnabled
default false; spec files only under `restore-specs/`; in-place whole-run refusal without allowInPlaceRestore; spec
file = source of truth for `targetInstance.spec` (new and in place); restore-patch base/over model with live snapshot
and entry seeding; only tpg-scale-instance / tpg-upgrade / tpg-patch change a restored CR, tpg-day0 BLOCKED
INSTANCE_RESTORED; restore-patch backupLocation/imagePullSecret win; TARGET_EXISTS; confirm only for in place;
RESTORED_VALUES_PATCH (detail of PATCH_REFUSED, both modes); strict snapshot with RESTORE_PATCH_NOT_RECORDED;
SOURCE_LOCATION_IN_USE; per-copy Secret; declared-but-undeployed target replaced (SPEC_FILE_REQUIRED kept); version
rule (lower/flavour block; skipMinorVersionCheck only the annotation); POST_RESTORE_BACKUP_FAILED warning; mutex per
target namespace; BACKUP_OF_OTHER_INSTANCE refusal; submit pair builder, hub and repo only.

Phase 7: schemas = shape, types, enums, patterns, required (always-mandatory), no unknown keys, no cross-field rules;
list inputs bracketed string or YAML sequence (examples prefer the sequence); clusterMap a string only; strict on
unquoted numbers (docs explain the YAML 1.1 rule); file names `params-<template without tpg->`; keep the hand-written
input tables (tests check Type, Mandatory, Default, enums) and a small generated block per section (schema path,
check-jsonschema command, example); example file = worked example 1; tests/params checks the examples and the doc
examples against schema, admission and, offline, the validate step; two worked examples per workflow (tpg-restore:
one pair named backup; two pairs PITR); tpg-backup-expire next to tpg-backup with renumbering; section 16 (restore)
restructured with a reason-code table; "(Round 23)" tags like earlier rounds; split 7a/7b with one review after 7b.
