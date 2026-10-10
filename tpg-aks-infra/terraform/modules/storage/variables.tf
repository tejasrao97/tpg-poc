variable "prefix" {
  description = "Name prefix; the account is <prefix>bkp<random6>."
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

variable "container_names" {
  description = "Private blob containers to create (one per target cluster)."
  type        = list(string)
}

variable "https_only" {
  description = "Secure transfer required. false also accepts HTTP (backup locations with enableSSL: false)."
  type        = bool
  default     = false
}

variable "logs_container_name" {
  description = "Private container for the archived Argo Workflows logs (artifact repository with archiveLogs)."
  type        = string
  default     = "argo-logs"
}

variable "logs_retention_days" {
  description = "Delete archived workflow logs older than this many days (lifecycle rule). 0: no rule."
  type        = number
  default     = 90
}

variable "replication_type" {
  description = "Storage replication (ZRS keeps backups available when one zone fails)."
  type        = string
  default     = "ZRS"
}

variable "soft_delete_days" {
  description = "Blob and container soft delete retention in days."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
