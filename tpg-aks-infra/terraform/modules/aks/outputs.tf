output "id" {
  description = "Cluster resource ID."
  value       = azurerm_kubernetes_cluster.cluster.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.cluster.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation."
  value       = azurerm_kubernetes_cluster.cluster.oidc_issuer_url
}

output "node_resource_group" {
  description = "AKS-owned node resource group."
  value       = azurerm_kubernetes_cluster.cluster.node_resource_group
}

output "kubelet_identity_object_id" {
  description = "Kubelet identity object ID."
  value       = azurerm_kubernetes_cluster.cluster.kubelet_identity[0].object_id
}
