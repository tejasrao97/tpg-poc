# CA bundles in the fleet repository

PEM files here can be named with `repo:ca-bundles/<file>` (Round 15, design decision D86):

- `backupCaBundleFile` of tpg-day0, tpg-create-instance and tpg-patch (input or clusterMap key at cluster or instance level): the CA bundle written as `backup.caBundle` of the instances with `backupEnableSSL=true`;
- `caBundleFile` of tpg-rotate-credential with `secretType=ca-bundle`: the bundle written to Vault as `tpg/ca-bundles/<secretName>`.

A bundle is one or more PEM certificates (`-----BEGIN CERTIFICATE-----`), for example the root certificate authorities of the storage account's blob endpoint (tpg-aks-infra Terraform output `backup_storage_ca_bundle`). The workflows refuse a file that holds no certificate or an expired one.

A bundle is public: it may live in Git. The other two sources are a file of the machine that submits the run (its contents travel in `patchFiles`) and a named bundle in Vault (`backupCaBundleVaultSecret`, written by `tpg-aks-infra/scripts/vault-secret.sh ca put`). Without any of them, the bundle in ConfigMap `argo/tpg-settings` (`backupCaBundle`) is used.
