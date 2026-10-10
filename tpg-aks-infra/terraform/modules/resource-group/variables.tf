variable "name" {
  description = "Resource group name."
  type        = string

  validation {
    condition     = can(regex("^[-\\w\\._\\(\\)]{1,90}$", var.name)) && !endswith(var.name, ".")
    error_message = "Resource group names are 1-90 characters: letters, digits, '-', '_', '.', '(' or ')', and cannot end with a period."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to the resource group."
  type        = map(string)
  default     = {}
}
