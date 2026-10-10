variable "name" {
  description = "Cluster name (also the DNS prefix)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group of the cluster resource."
  type        = string
}

variable "node_resource_group" {
  description = "Name of the AKS-owned node resource group. Must not exist before the cluster is created."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version, or null for the AKS default."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "Free, Standard or Premium."
  type        = string
  default     = "Standard"
}

variable "identity_id" {
  description = "User-assigned control plane identity ID."
  type        = string
}

variable "subnet_id" {
  description = "Node subnet ID. null places the nodes in an AKS-managed VNet."
  type        = string
  default     = null
}

variable "authorized_ip_ranges" {
  description = "API server authorized IP ranges. An empty list means a public API server open to all addresses."
  type        = list(string)
  default     = []
}

variable "outbound_ip_address_ids" {
  description = "Public IP IDs for egress. An empty list uses one AKS-managed outbound IP."
  type        = list(string)
  default     = []
}

variable "network" {
  description = "Azure CNI Overlay CIDRs."
  type = object({
    pod_cidr       = string
    service_cidr   = string
    dns_service_ip = string
  })
}

variable "os_sku" {
  description = "Node OS SKU for every pool."
  type        = string
  default     = "Ubuntu2404"
}

variable "autoscaling" {
  description = "Cluster autoscaler switch for every pool. Node counts are set per pool."
  type = object({
    enabled = bool
  })
}

variable "auto_scaler_profile" {
  description = "Cluster autoscaler profile, applied when autoscaling is enabled."
  type = object({
    expander                      = string
    balance_similar_node_groups   = bool
    scale_down_unneeded           = string
    scale_down_delay_after_add    = string
    skip_nodes_with_local_storage = bool
    max_node_provisioning_time    = string
  })
}

variable "system_pool" {
  description = "System (default) node pool. zones holds the availability zones it spans; node_count is the initial count (the autoscaler changes it later); min_count and max_count bound the autoscaler."
  type = object({
    vm_size              = string
    os_disk_type         = string
    os_disk_size_gb      = number
    max_pods             = number
    zones                = list(string)
    node_count           = number
    min_count            = number
    max_count            = number
    only_critical_addons = bool
  })

  validation {
    condition     = length(var.system_pool.zones) >= 1 && length(var.system_pool.zones) <= 3
    error_message = "The system pool spans 1 to 3 availability zones."
  }

  validation {
    condition     = var.system_pool.node_count >= length(var.system_pool.zones) && var.system_pool.min_count >= length(var.system_pool.zones)
    error_message = "The system pool needs one node per selected zone: node_count and min_count must be at least length(zones)."
  }

  validation {
    condition     = var.system_pool.min_count <= var.system_pool.node_count && var.system_pool.node_count <= var.system_pool.max_count
    error_message = "The system pool needs min_count <= node_count <= max_count."
  }
}

variable "user_pools" {
  description = "Additional user node pools keyed by pool name (max 12 lowercase alphanumeric characters). zones holds the availability zones the pool spans; node_count is the initial count; min_count and max_count bound the autoscaler."
  type = map(object({
    vm_size         = string
    os_disk_type    = string
    os_disk_size_gb = number
    max_pods        = number
    zones           = list(string)
    node_count      = number
    min_count       = number
    max_count       = number
    node_labels     = optional(map(string), {})
    node_taints     = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for p in values(var.user_pools) : length(p.zones) >= 1 && length(p.zones) <= 3])
    error_message = "Every user pool spans 1 to 3 availability zones."
  }

  validation {
    condition     = alltrue([for p in values(var.user_pools) : p.node_count >= length(p.zones) && p.min_count >= length(p.zones)])
    error_message = "Every user pool needs one node per selected zone: node_count and min_count must be at least length(zones)."
  }

  validation {
    condition     = alltrue([for p in values(var.user_pools) : p.min_count <= p.node_count && p.node_count <= p.max_count])
    error_message = "Every user pool needs min_count <= node_count <= max_count."
  }
}

variable "upgrade" {
  description = "Node surge, upgrade channels and an optional weekly maintenance window."
  type = object({
    max_surge         = string
    automatic_channel = optional(string)
    node_os_channel   = string
    maintenance_window = optional(object({
      day_of_week    = string
      start_time     = string
      duration_hours = number
      utc_offset     = string
    }))
  })
}

variable "workload_identity_enabled" {
  description = "Enable Microsoft Entra Workload ID (the OIDC issuer is always enabled)."
  type        = bool
  default     = true
}

variable "image_cleaner" {
  description = "Image Cleaner settings."
  type = object({
    enabled        = bool
    interval_hours = number
  })
}

variable "azure_policy_enabled" {
  description = "Enable the Azure Policy add-on."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for Container Insights. null disables the add-on."
  type        = string
  default     = null
}

variable "monitor_metrics_enabled" {
  description = "Enable Azure Monitor managed Prometheus metrics."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "acns_enabled" {
  description = "Advanced Container Networking Services security (FQDN filtering in CiliumNetworkPolicy)."
  type        = bool
  default     = false
}
