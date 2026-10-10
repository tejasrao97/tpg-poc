# tpg-credential-writer: the write step of tpg-rotate-credential (Round 15, design
# decision D87; role tpg-credential-writer, ServiceAccount argo/tpg-credential-writer).
# Writes the fleet credentials, the CA bundles and the custom secrets as new KV v2
# versions; it reads them back to verify. The new value reaches the step in a
# response-wrapping token, which the step unwraps with the token itself
# (sys/wrapping/unwrap needs no policy). Nothing else: no other path, no delete.
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/shared/github-push" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/shared/github-read" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/shared/backup-storage" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/shared/monitoring-remote-write" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/ca-bundles/*" {
  capabilities = ["create", "update", "read"]
}
path "tpg/data/custom/*" {
  capabilities = ["create", "update", "read"]
}
