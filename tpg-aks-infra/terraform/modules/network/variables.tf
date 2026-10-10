variable "network_mode" {
  description = "byo (VNet, subnets and hub egress IP created here) or managed (AKS-managed VNets)."
  type        = string

  validation {
    condition     = contains(["byo", "managed"], var.network_mode)
    error_message = "network_mode must be byo or managed."
  }
}

variable "prefix" {
  description = "Name prefix."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for every network resource."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "vnet_cidr" {
  description = "VNet address space. Each cluster gets cidrsubnet(vnet_cidr, 6, index), a /22 for a /16; the jumpbox range is taken from the last of these slots (63)."
  type        = string
}

variable "subnet_indexes" {
  description = "Map of cluster name to subnet index."
  type        = map(number)
}

variable "hub_cluster_name" {
  description = "Hub cluster name, used for the egress IP name."
  type        = string
}

variable "availability_zones" {
  description = "Zones for the hub egress IP."
  type        = list(string)
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "jumpbox_subnet_enabled" {
  description = "Create the subnet snet-jumpbox in the VNet (byo mode only)."
  type        = bool
  default     = false
}
