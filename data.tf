############################################
# Phase 1 Step 2 — Database (PostgreSQL Flexible Server)
# SKU: Burstable B1MS, 32GB SSD
############################################

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "psql-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  administrator_login    = var.postgres_admin_username
  administrator_password = var.postgres_admin_password

  sku_name   = var.postgres_sku_name
  storage_mb = var.postgres_storage_mb
  version    = var.postgres_version

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = false # LRS, matching the proposal's Essential/Full tier costing

  auto_grow_enabled = true

  tags = local.common_tags

  lifecycle {
    # Password rotation shouldn't force a server recreate; zone is picked by
    # Azure at create time and can't be changed to "unset" afterwards.
    ignore_changes = [administrator_password, zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = replace(var.project_name, "-", "_")
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allows Azure-hosted resources (App Service, etc.) to reach the server.
# This is the standard "Allow public access from any Azure service" rule —
# it does NOT open the server to the public internet.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Optional: lets one named IP (engineer running migrations) connect directly.
resource "azurerm_postgresql_flexible_server_firewall_rule" "admin_ip" {
  count            = var.allowed_admin_ip != "" ? 1 : 0
  name             = "AllowAdminIP"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = var.allowed_admin_ip
  end_ip_address   = var.allowed_admin_ip
}

############################################
# Phase 1 Step 2 — Cache (Azure Managed Redis)
# SKU: Balanced B0, high availability. Replaces the proposal's Azure Cache
# for Redis Standard C0: Azure no longer allows new Azure Cache for Redis
# instances (retirement), and B0 HA is cheaper (~$26/mo vs ~$40/mo).
############################################

resource "azurerm_managed_redis" "main" {
  name                = "redis-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku_name                  = var.redis_sku_name
  high_availability_enabled = true

  default_database {
    # The apps connect with a key-based rediss:// URL, and Managed Redis
    # disables access keys by default.
    access_keys_authentication_enabled = true
    # Single endpoint, so non-cluster-aware Redis clients work unchanged.
    clustering_policy = "EnterpriseCluster"
    client_protocol   = "Encrypted"
  }

  tags = local.common_tags
}

############################################
# Phase 1 Step 3 — Storage (Blob) for product images
# SKU: Hot tier, LRS, ~40GB (no fixed quota to set — pay-as-used)
############################################

resource "azurerm_storage_account" "main" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 30
    }
    # Point-in-time restore window must be < delete retention above.
    restore_policy {
      days = 29
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.common_tags

  # Azure Backup (backup.tf) raises these to fit its 30-day operational
  # policy (delete retention 35, restore 30, change feed 35). Don't revert.
  lifecycle {
    ignore_changes = [
      blob_properties[0].delete_retention_policy,
      blob_properties[0].restore_policy,
      blob_properties[0].change_feed_retention_in_days,
    ]
  }
}

resource "azurerm_storage_container" "product_images" {
  name                  = "product-images"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}
