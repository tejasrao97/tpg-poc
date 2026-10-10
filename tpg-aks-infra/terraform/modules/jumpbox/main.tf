# Operator jumpbox: one Linux VM with a static public IP, SSH (key only) from
# admin_allowed_cidrs, and a user-assigned identity for az login --identity.
# The tools, by jumpbox_setup_method (Round 19): remote-exec, the root module
# copies scripts/ to the admin user's home over SSH and runs
# scripts/jumpbox/setup-jumpbox.sh there (jumpbox-provision.tf), with the key pair
# generated below; cloud-init, custom_data below writes setup-jumpbox.sh to the
# admin user's home and runs it once at first boot (cloud_init_script set).
locals {
  name = "${var.prefix}-jumpbox"

  # Marketplace images. The Ubuntu and RHEL images need no plan (RHEL is
  # pay-as-you-go: the RHEL subscription is billed with the VM). The official
  # Rocky Linux images (publisher resf) carry a Marketplace plan, so their
  # terms must be accepted once per subscription before the first apply:
  #   az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
  images = {
    "ubuntu-24.04" = { publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", plan = false }
    "ubuntu-22.04" = { publisher = "Canonical", offer = "0001-com-ubuntu-server-jammy", sku = "22_04-lts-gen2", plan = false }
    "rhel-9"       = { publisher = "RedHat", offer = "RHEL", sku = "9-lvm-gen2", plan = false }
    "rocky-9"      = { publisher = "resf", offer = "rockylinux-x86_64", sku = "9-base", plan = true }
  }
  image = local.images[var.os]

  subnet_id = var.create_network ? azurerm_subnet.jumpbox[0].id : var.subnet_id

  # cloud-init method only; the script travels gzip-compressed (Azure limits
  # custom_data to 87380 base64 characters)
  custom_data = var.cloud_init_script == null ? null : base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    setup_script_gz_b64 = base64gzip(var.cloud_init_script)
    admin_username      = var.admin_username
  }))

  # The generated key always; the operator's own key as well when one is given.
  # (concat, not compact: the list length stays known while the generated key is not)
  ssh_public_keys = concat(
    [trimspace(tls_private_key.jumpbox.public_key_openssh)],
    var.ssh_public_key == null ? [] : [trimspace(var.ssh_public_key)],
  )
}

# SSH key pair of the admin user, used by the Terraform provisioners and
# available to the operator: terraform output -raw jumpbox_ssh_private_key.
# The private key is stored in the Terraform state.
resource "tls_private_key" "jumpbox" {
  algorithm = "ED25519"
}

# network_mode = "managed" has no VNet of ours, so the jumpbox gets its own.
resource "azurerm_virtual_network" "jumpbox" {
  count = var.create_network ? 1 : 0

  name                = "vnet-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "jumpbox" {
  count = var.create_network ? 1 : 0

  name                 = "snet-jumpbox"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.jumpbox[0].name
  address_prefixes     = [var.address_prefix]
}

# Static, so the address can stay in the API server authorized IP ranges.
resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

# SSH from admin_allowed_cidrs only. The default rules deny all other inbound
# traffic from the internet.
resource "azurerm_network_security_group" "jumpbox" {
  name                = "nsg-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.admin_allowed_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  network_interface_id      = azurerm_network_interface.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

resource "azurerm_user_assigned_identity" "jumpbox" {
  name                = "id-jumpbox"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Role assignments need Microsoft.Authorization/roleAssignments/write. With
# create_role_assignments = false they are skipped and the module outputs the
# az commands instead (same pattern as modules/identity). They live here rather
# than in modules/identity so that the VM does not wait for the AKS clusters
# whose IDs are the scopes.
resource "azurerm_role_assignment" "jumpbox" {
  for_each = var.create_role_assignments ? var.role_assignments : {}

  scope                            = each.value.scope
  role_definition_name             = each.value.role
  principal_id                     = azurerm_user_assigned_identity.jumpbox.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "vm-${local.name}"
  computer_name                   = local.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.jumpbox.id]
  custom_data                     = local.custom_data
  tags                            = var.tags

  dynamic "admin_ssh_key" {
    for_each = local.ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    name                 = "osdisk-${local.name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = "latest"
  }

  dynamic "plan" {
    for_each = local.image.plan ? [1] : []
    content {
      publisher = local.image.publisher
      product   = local.image.offer
      name      = local.image.sku
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.jumpbox.id]
  }

  # Serial console and boot screenshots when SSH does not answer.
  boot_diagnostics {}

  # A change of admin_ssh_key replaces the VM: a jumpbox created before Round 16
  # (cloud-init, no generated key) is replaced by the first apply of this version.

  lifecycle {
    # custom_data only runs at first boot, and a change would replace the VM
    # (and the admin user's home): a newer setup-jumpbox.sh reaches a cloud-init
    # jumpbox through deploy-scripts/deploy.sh copy, which runs it again.
    ignore_changes = [custom_data]

    precondition {
      condition     = try(length(local.custom_data) <= 87380, true) # null (no cloud-init): true
      error_message = "The cloud-init data for the jumpbox exceeds the Azure custom_data limit of 87380 base64 characters; shorten scripts/jumpbox/setup-jumpbox.sh or use jumpbox_setup_method = \"remote-exec\"."
    }
  }
}
