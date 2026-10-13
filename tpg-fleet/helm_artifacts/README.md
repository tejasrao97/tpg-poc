# Helm artifacts

`instance/` holds the charts of the Postgres instances: `tpg-instance/` (the chart the
`tpg-instances` ApplicationSet deploys, with its own `overlays/` and `patches/`) and
`crd-reference/` (the reference chart of every Tanzu Postgres kind).
`operator/` holds the operator values files: `overlays/` and `patches/`, see their READMEs.

`instance/tpg-instance/` has two more folders for tpg-restore (Round 23): `restore-specs/` holds the
instance spec files that a restore reads (`targetInstanceSpecFilePath`; the chart never reads them) and
`restore-patch/` the spec of every instance a restore left, which the chart renders the restored
Postgres from. Section 16 of `docs/workflow-commands.md` describes the restore.

tpg-day0 and tpg-create-instance apply overlay files at the initial deployment
(Round 22); tpg-patch changes what runs afterwards with patch files that stack on
top of them. Instance overlays live in `helm_artifacts/instance/tpg-instance/overlays/`
and instance patches in `helm_artifacts/instance/tpg-instance/patches/` (the chart reads
them); operator overlays live in `helm_artifacts/operator/overlays/` and operator patches
in `helm_artifacts/operator/patches/`, see their READMEs.
