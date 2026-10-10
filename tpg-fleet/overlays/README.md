# Overlay files

tpg-day0 and tpg-create-instance apply overlay files at the initial deployment
(Round 22); tpg-patch changes what runs afterwards with patch files that stack on
top of them (`patches/`). Instance overlays live in `charts/tpg-instance/overlays/`
(the chart reads them); operator overlays live in `overlays/operator/`, see its
README.
