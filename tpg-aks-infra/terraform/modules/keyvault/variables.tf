variable "prefix" {
  description = "Name prefix; the Key Vault is kv<prefix><random6>."
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

variable "tenant_id" {
  description = "Microsoft Entra tenant of the Key Vault."
  type        = string
}

variable "deployer_object_id" {
  description = "Object ID of the identity running Terraform; an access policy gives it key create, get, list, update, delete, recover and purge so it can create the unseal key and remove it on destroy."
  type        = string
}

variable "key_name" {
  description = "Name of the RSA key that wraps the Vault root key (auto-unseal)."
  type        = string
  default     = "vault-unseal"
}

variable "purge_protection_enabled" {
  description = "Purge protection: a deleted vault or key stays recoverable for soft_delete_retention_days and cannot be purged early. Off by default for the POC, so terraform destroy removes the Key Vault; deleting the key then destroys the Vault data for good."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Days a deleted Key Vault or key stays recoverable (7 to 90)."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
