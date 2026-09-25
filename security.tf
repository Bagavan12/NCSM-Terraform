############################################
# Phase 1 Step 3 — Key Vault (RBAC-authorized, not access-policy)
# SKU: Standard
############################################

resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tenant_id = data.azurerm_client_config.current.tenant_id
  sku_name  = "standard"

  enable_rbac_authorization     = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true

  tags = local.common_tags
}

# Lets the identity running `terraform apply` write the secrets below.
# Without this, secret creation fails with a 403 on an RBAC-authorized vault.
# Also granted to key_vault_admin_object_ids, so the customer's admins keep
# secret access whichever identity (GitHub Actions or a person) runs apply.
resource "azurerm_role_assignment" "terraform_kv_secrets_officer" {
  for_each             = toset(concat([data.azurerm_client_config.current.object_id], var.key_vault_admin_object_ids))
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# Role assignments take a short while to propagate. Writing secrets
# immediately after the assignment above is a common source of a 403 on the
# first `apply` — this sleep absorbs that without needing a second run.
resource "time_sleep" "wait_for_kv_rbac" {
  depends_on      = [azurerm_role_assignment.terraform_kv_secrets_officer]
  create_duration = "30s"
}

############################################
# Secret placeholders
# Blank values deploy fine — fill them in via `az keyvault secret set` or the
# portal once GKash/SMTP credentials are issued, without touching Terraform.
############################################

resource "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = "postgres-connection-string"
  key_vault_id = azurerm_key_vault.main.id
  value        = "postgresql://${var.postgres_admin_username}:${var.postgres_admin_password}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.app.name}?sslmode=require"

  depends_on = [time_sleep.wait_for_kv_rbac]
}

resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  key_vault_id = azurerm_key_vault.main.id
  value        = "rediss://:${azurerm_managed_redis.main.default_database[0].primary_access_key}@${azurerm_managed_redis.main.hostname}:${azurerm_managed_redis.main.default_database[0].port}/0"

  depends_on = [time_sleep.wait_for_kv_rbac]
}

resource "azurerm_key_vault_secret" "storage_connection_string" {
  name         = "storage-connection-string"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_storage_account.main.primary_connection_string

  depends_on = [time_sleep.wait_for_kv_rbac]
}

resource "azurerm_key_vault_secret" "gkash_merchant_key" {
  name         = "gkash-merchant-key"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.gkash_merchant_key != "" ? var.gkash_merchant_key : "CHANGEME-set-after-gkash-onboarding"

  depends_on = [time_sleep.wait_for_kv_rbac]

  lifecycle {
    ignore_changes = [value] # so a manual portal update isn't clobbered by the next apply
  }
}

resource "azurerm_key_vault_secret" "gkash_secret_key" {
  name         = "gkash-secret-key"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.gkash_secret_key != "" ? var.gkash_secret_key : "CHANGEME-set-after-gkash-onboarding"

  depends_on = [time_sleep.wait_for_kv_rbac]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "smtp_username" {
  name         = "smtp-username"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.smtp_username != "" ? var.smtp_username : "CHANGEME"

  depends_on = [time_sleep.wait_for_kv_rbac]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "smtp_password" {
  name         = "smtp-password"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.smtp_password != "" ? var.smtp_password : "CHANGEME"

  depends_on = [time_sleep.wait_for_kv_rbac]

  lifecycle {
    ignore_changes = [value]
  }
}

############################################
# RBAC — app identities get least-privilege access to their own resources.
# No admin keys are handed to the application anywhere in this module.
############################################

resource "azurerm_role_assignment" "web_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.web.identity[0].principal_id
}

resource "azurerm_role_assignment" "worker_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.worker.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.web.identity[0].principal_id
}

resource "azurerm_role_assignment" "worker_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.worker.identity[0].principal_id
}

# Owner, not Contributor: the app reads/writes blob index tags (Defender
# scan verdicts), which Contributor does not include.
resource "azurerm_role_assignment" "web_blob_data_owner" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_web_app.web.identity[0].principal_id
}

# Owner, not Contributor: the app reads/writes blob index tags (Defender
# scan verdicts), which Contributor does not include.
resource "azurerm_role_assignment" "worker_blob_data_owner" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_web_app.worker.identity[0].principal_id
}

# Kept the existing (pre-for_each) assignment for the customer admin.
moved {
  from = azurerm_role_assignment.terraform_kv_secrets_officer
  to   = azurerm_role_assignment.terraform_kv_secrets_officer["43168f21-3466-47a8-aad6-c03d7fbefffd"]
}

# The old Contributor grants can't be deleted: Azure Backup puts a
# CanNotDelete lock (AzureBackupLock-DoNotDelete) on the protected storage
# account, which also blocks deleting role assignments scoped to it. Stop
# managing them instead; Owner (above) is a superset, so they're harmless.
removed {
  from = azurerm_role_assignment.web_blob_data_contributor
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_role_assignment.worker_blob_data_contributor
  lifecycle {
    destroy = false
  }
}
