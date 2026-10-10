terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    # reads the certificate chain of the backup storage blob endpoint (modules/storage)
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Local state by design (POC). terraform.tfstate contains sensitive values
  # such as the backup storage account key: never commit it.
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # terraform destroy removes the resource group even if something was
      # added to it outside Terraform.
      prevent_deletion_if_contains_resources = false
    }
    # Unseal Key Vault (vault_unseal_mode = "azure-keyvault"), written out
    # rather than left to the provider defaults:
    #   - on destroy the provider deletes the vault-unseal key and then purges it.
    #     The purge needs the "Purge" key permission, which the deployer's access
    #     policy grants (modules/keyvault). Without it the first destroy failed
    #     with "does not have keys purge permission" (403 ForbiddenByPolicy) and
    #     only a second run finished, after the key had already been deleted.
    #   - with purge protection on, Azure refuses every purge, so the provider
    #     must not attempt one: the deleted key and vault stay soft-deleted for
    #     key_vault_soft_delete_days.
    key_vault {
      purge_soft_deleted_keys_on_destroy = !var.key_vault_purge_protection
      purge_soft_delete_on_destroy       = !var.key_vault_purge_protection
      recover_soft_deleted_key_vaults    = true
      recover_soft_deleted_keys          = true
    }
  }
}

data "azurerm_client_config" "current" {}
