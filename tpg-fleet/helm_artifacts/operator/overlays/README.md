# Operator overlay files

tpg-day0 stores the operator values file it receives (`operatorValuesOverlayFilePath`,
Round 22; before that `operatorValuesPatchFilePath`) here:
`helm_artifacts/operator/overlays/<name>-<uid>.yaml`, recorded per cluster as
`clusters.<cluster>.operator.overlays.values.current` (and `previous`) in
`clusters/fleet.yaml`. The current file of a cluster is copied to
`helm_artifacts/operator/overlays/clusters/<cluster>.yaml`. The `tpg-operator` ApplicationSet passes
that copy to the operator chart as a value file before the patch copy
(`helm_artifacts/operator/patches/clusters/<cluster>.yaml`, written by tpg-patch), so a patch wins
over an overlay. Both paths are fixed so that a sync at the commit of a pull request
branch reads that branch's values. `scripts/validate.sh` checks that each copy equals
its current file. Do not add or edit the stored files or the copies by hand: write
the file on the machine that submits the run and pass it as
`operatorValuesOverlayFilePath` (see `docs/workflow-commands.md`, tpg-day0). A team
file that runs name with `repo:helm_artifacts/operator/overlays/<file>` may be added here through a
reviewed commit, with a name that is not a stored name; a run copies it to a stored
file.

An operator overlay may set only the keys of an operator patch: `operatorImage` (the
tag must be the cluster's operator version), `instanceRegistryRepo`,
`ferretDBImageRepo`, `dockerRegistrySecretName`, `certManagerClusterIssuerName`,
`certManagerNamespace`, `resources` (`limits` and `requests`, `cpu` and `memory`) and
`enableSecurityContext`. A cluster whose operator already runs keeps its current
overlay when a run sends an identical file; another file is refused
(`OVERLAY_USE_TPG_PATCH`): use tpg-patch. `example-operator-overlay-ov1o1.yaml` is an
example in the stored form, referenced by `clusters/fleet.example.yaml`.
