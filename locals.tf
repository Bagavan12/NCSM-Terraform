resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = true
}

locals {
  name_suffix = "${var.project_name}-${var.environment}"

  # Storage Account / ACR / Key Vault names must be globally unique across
  # all of Azure and are character/length constrained, so they get a random
  # suffix and have hyphens stripped where the resource type disallows them.
  raw_alnum = lower(replace("${var.project_name}${var.environment}", "-", ""))

  storage_account_name = substr("st${local.raw_alnum}${random_string.suffix.result}", 0, 24)
  acr_name             = substr("acr${local.raw_alnum}${random_string.suffix.result}", 0, 50)
  key_vault_name       = substr("kv-${local.raw_alnum}-${random_string.suffix.result}", 0, 24)
  backup_vault_name    = "bvault-${local.name_suffix}-${random_string.suffix.result}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}
