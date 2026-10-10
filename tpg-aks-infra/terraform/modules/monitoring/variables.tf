variable "prefix" {
  description = "Name prefix."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "cluster_ids" {
  description = "Map of cluster name to AKS resource ID (keys must be known at plan time)."
  type        = map(string)
}

variable "enable_container_insights" {
  description = "Create a Log Analytics workspace and Container Insights data collection."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "enable_azure_monitor" {
  description = "Create managed Prometheus and Azure Managed Grafana."
  type        = bool
  default     = false
}

variable "grafana_major_version" {
  description = "Azure Managed Grafana major version."
  type        = number
  default     = 12
}

variable "grafana_admin_object_id" {
  description = "Object ID granted Grafana Admin (the identity running Terraform)."
  type        = string
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "create_role_assignments" {
  description = "Create the Managed Grafana role assignments. With false they are skipped and listed in role_assignment_commands."
  type        = bool
  default     = true
}
