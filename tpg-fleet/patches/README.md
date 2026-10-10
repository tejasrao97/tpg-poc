# Operator patch files

tpg-patch stores the operator values files it receives here (Round 14, design
decisions D76 to D79; Round 15, D83); tpg-day0 stores its operator values **overlay**
in `overlays/operator/` (Round 22, see its README), and the `tpg-operator` Application
reads the overlay copy first and this patch copy after it, so a patch wins:
`patches/operator/<name>-<uid>.yaml`, recorded per cluster as
`clusters.<cluster>.operator.patches.values.current` (and `previous`) in
`clusters/fleet.yaml`. The current file of a cluster is copied to
`patches/operator/clusters/<cluster>.yaml`, which the `tpg-operator` Application reads
as a value file (`$fleet/patches/operator/clusters/<cluster>.yaml`); a fixed path, so
a sync at the commit of a tpg-patch pull request branch reads that branch's values.
`scripts/validate.sh` checks that each copy equals its current file. Do not add or
edit the stored files or the copies by hand: write the file on the machine that
submits the run and pass it as `operatorValuesPatchFilePath` (see
`docs/workflow-commands.md`, tpg-patch). A team file that runs name with
`repo:patches/operator/<file>` may be added here through a reviewed commit, with a
name that is not a stored name; a run copies it to a stored file.

An operator values file may set only `operatorImage` (the tag must be the cluster's
operator version; tpg-upgrade moves it with the version), `instanceRegistryRepo`,
`ferretDBImageRepo`, `dockerRegistrySecretName`, `certManagerClusterIssuerName`,
`certManagerNamespace`, `resources` (`limits` and `requests`, `cpu` and `memory`) and
`enableSecurityContext`. `example-operator-values-ex4m3.yaml` is an example in the
stored form, referenced by `clusters/fleet.example.yaml`. Instance patch files live
in `charts/tpg-instance/patches/`.
