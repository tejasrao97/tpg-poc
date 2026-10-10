variable "resource_group_name" {
  description = "Resource group for the identities."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "identities" {
  description = <<-EOT
    Map of identity name to its role assignments and federated credentials.
    Map keys of roles and federated_credentials must be known at plan time.
      roles                 = { <key> = { scope = <resource ID>, role = <role name> } }
      federated_credentials = { <name> = { issuer = <OIDC issuer URL>, subject = "system:serviceaccount:<ns>:<sa>" } }
  EOT
  type = map(object({
    roles = optional(map(object({
      scope = string
      role  = string
    })), {})
    federated_credentials = optional(map(object({
      issuer  = string
      subject = string
    })), {})
  }))
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "create_role_assignments" {
  description = "Create the role assignments in identities[*].roles. With false they are skipped and listed in the output role_assignment_commands."
  type        = bool
  default     = true
}
