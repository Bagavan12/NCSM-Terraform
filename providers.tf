############################################
# NCSM Store — Terraform & Provider Setup
############################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # State lives in the customer's subscription, not on anyone's laptop.
  # rg-ncsm-store-tfstate is bootstrapped outside Terraform (see infra/README.md)
  # and carries a CanNotDelete lock.
  backend "azurerm" {
    resource_group_name  = "rg-ncsm-store-tfstate"
    storage_account_name = "sttfstatencsmytsr"
    container_name       = "tfstate"
    key                  = "ncsm-store.tfstate"
  }
}

provider "azurerm" {
  # Register only the providers this config uses, instead of the ~70 in the
  # provider's default "legacy" set (slow, and flaky on fresh subscriptions).
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.Cache",
    "Microsoft.Cdn",
    "Microsoft.ContainerRegistry",
    "Microsoft.Consumption",
    "Microsoft.DataProtection",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.Insights",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Security",
    "Microsoft.Storage",
    "Microsoft.Web",
  ]

  features {
    key_vault {
      # Keep soft-deleted vaults recoverable; don't hard-purge on destroy.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # Safety net: `terraform destroy` won't silently nuke a populated RG.
      prevent_deletion_if_contains_resources = true
    }
  }

  # subscription_id / tenant_id are picked up from `az login` context or the
  # ARM_SUBSCRIPTION_ID / ARM_TENANT_ID env vars — see README "Authentication".
}

# Used to grant the identity running `terraform apply` rights to write
# Key Vault secrets (the vault below is RBAC-authorized, not access-policy).
data "azurerm_client_config" "current" {}
