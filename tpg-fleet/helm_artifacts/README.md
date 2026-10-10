# Helm artifacts

`instance/` holds the charts of the Postgres instances: `tpg-instance/` (the chart the
`tpg-instances` ApplicationSet deploys, with its own `overlays/` and `patches/`) and
`crd-reference/` (the reference chart of every Tanzu Postgres kind).
`operator/` holds the operator values files: `overlays/` and `patches/`, see their READMEs.

tpg-day0 and tpg-create-instance apply overlay files at the initial deployment
(Round 22); tpg-patch changes what runs afterwards with patch files that stack on
top of them. Instance overlays live in `helm_artifacts/instance/tpg-instance/overlays/`
and instance patches in `helm_artifacts/instance/tpg-instance/patches/` (the chart reads
them); operator overlays live in `helm_artifacts/operator/overlays/` and operator patches
in `helm_artifacts/operator/patches/`, see their READMEs.
