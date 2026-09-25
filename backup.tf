############################################
# Phase 1 Step 6 — Azure Backup (Blob operational backup)
#
# PostgreSQL's own 7-day PITR is native to the Flexible Server resource
# (see postgres_backup_retention_days in data.tf) and needs no separate
# vault. This vault covers Blob Storage, matching the proposal's dedicated
# "Azure Backup" line item.
############################################

resource "azurerm_data_protection_backup_vault" "main" {
  name                = local.backup_vault_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  datastore_type      = "VaultStore"
  redundancy          = "LocallyRedundant" # matches the proposal's "25GB vault, LRS redundancy"

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

resource "azurerm_role_assignment" "backup_vault_storage_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = azurerm_data_protection_backup_vault.main.identity[0].principal_id
}

resource "time_sleep" "wait_for_backup_rbac" {
  depends_on      = [azurerm_role_assignment.backup_vault_storage_contributor]
  create_duration = "30s"
}

resource "azurerm_data_protection_backup_policy_blob_storage" "main" {
  name     = "blob-operational-backup"
  vault_id = azurerm_data_protection_backup_vault.main.id

  operational_default_retention_duration = "P30D"
}

resource "azurerm_data_protection_backup_instance_blob_storage" "main" {
  name               = "backup-${local.storage_account_name}"
  vault_id           = azurerm_data_protection_backup_vault.main.id
  location           = azurerm_resource_group.main.location
  storage_account_id = azurerm_storage_account.main.id
  backup_policy_id   = azurerm_data_protection_backup_policy_blob_storage.main.id

  depends_on = [time_sleep.wait_for_backup_rbac]
}
