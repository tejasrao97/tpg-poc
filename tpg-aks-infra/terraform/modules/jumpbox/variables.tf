variable "prefix" {
  description = "Name prefix."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for every jumpbox resource."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "create_network" {
  description = "true (network_mode managed): create a VNet and subnet for the VM here. false (byo): use subnet_id."
  type        = bool
}

variable "subnet_id" {
  description = "Existing subnet for the VM (byo mode: snet-jumpbox). Ignored when create_network is true."
  type        = string
  default     = null
}

variable "address_prefix" {
  description = "Address range of the VNet and subnet created when create_network is true."
  type        = string
}

variable "admin_allowed_cidrs" {
  description = "Source CIDRs allowed to reach SSH (TCP 22)."
  type        = list(string)
}

variable "admin_username" {
  description = "Admin user on the VM."
  type        = string
}

variable "ssh_public_key" {
  description = "Optional OpenSSH public key of the admin user, authorized next to the key pair generated here. Password authentication is disabled."
  type        = string
  default     = null
}

variable "os" {
  description = "Operating system image: ubuntu-24.04, ubuntu-22.04, rhel-9 or rocky-9."
  type        = string

  validation {
    condition     = contains(["ubuntu-24.04", "ubuntu-22.04", "rhel-9", "rocky-9"], var.os)
    error_message = "os must be ubuntu-24.04, ubuntu-22.04, rhel-9 or rocky-9."
  }
}

variable "vm_size" {
  description = "VM size."
  type        = string
}

variable "os_disk_gb" {
  description = "OS disk size in GB (Premium_LRS)."
  type        = number
}

variable "cloud_init_script" {
  description = "jumpbox_setup_method = cloud-init: content of scripts/jumpbox/setup-jumpbox.sh, written to the VM by cloud-init and run once at first boot. null: no custom_data (remote-exec, or no provisioning)."
  type        = string
  default     = null
}

variable "role_assignments" {
  description = <<-EOT
    Roles of the jumpbox identity. Map keys must be known at plan time.
      { <key> = { scope = <resource ID>, role = <role name> } }
  EOT
  type = map(object({
    scope = string
    role  = string
  }))
  default = {}
}

variable "create_role_assignments" {
  description = "Create the role assignments. With false they are skipped and listed in the output role_assignment_commands."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
