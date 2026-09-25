############################################
# Application secrets and runtime configuration
#
# Every key the app refuses to boot without in production is generated here
# and written straight to Key Vault, so no operator machine ever holds them.
# The app loads the "NCSM-*" secrets itself via its managed identity
# (load_key_vault_secrets() in app.py); the rest reach it as Key Vault
# references in app settings.
#
# BACK UP pii-encryption-key and NCSM-Backup-Encryption-Key outside this
# subscription: losing either makes the orders table / every backup unreadable.
# Key Vault purge protection guards against deletion, not against losing the
# vault's subscription.
############################################

# Fernet / URL-safe base64 32-byte keys.
resource "random_bytes" "fernet" {
  for_each = toset(["mfa", "pii", "backup"])
  length   = 32
}

# High-entropy alphanumeric secrets (no URL- or shell-hostile characters).
resource "random_password" "app" {
  for_each = toset([
    "flask", "audit_integrity", "audit_pseudonymization", "api_key_pepper",
    "rate_limit_hmac", "metrics_token", "db_app", "db_auditor",
  ])
  length  = 64
  special = false
}

locals {
  fernet = { for k, v in random_bytes.fernet : k => replace(replace(v.base64, "+", "-"), "/", "_") }

  pg_host = azurerm_postgresql_flexible_server.main.fqdn
  pg_db   = azurerm_postgresql_flexible_server_database.app.name

  # Secrets the app fetches from Key Vault by these exact names.
  app_loaded_secrets = {
    "NCSM-Flask-Secret-Key"           = random_password.app["flask"].result
    "NCSM-Mfa-Encryption-Key"         = local.fernet["mfa"]
    "NCSM-Backup-Encryption-Key"      = local.fernet["backup"]
    "NCSM-Audit-Integrity-Key"        = random_password.app["audit_integrity"].result
    "NCSM-Audit-Pseudonymization-Key" = random_password.app["audit_pseudonymization"].result
    "NCSM-API-Key-Pepper"             = random_password.app["api_key_pepper"].result
    "NCSM-Metrics-Bearer-Token"       = random_password.app["metrics_token"].result
  }

  # Secrets passed as @Microsoft.KeyVault references in app settings.
  referenced_secrets = {
    "pii-encryption-key"  = local.fernet["pii"]
    "rate-limit-hmac-key" = random_password.app["rate_limit_hmac"].result
    "app-database-url"    = "postgresql+psycopg://ncsm_app:${random_password.app["db_app"].result}@${local.pg_host}:5432/${local.pg_db}?sslmode=require"
    "db-app-password"     = random_password.app["db_app"].result
    "db-auditor-password" = random_password.app["db_auditor"].result
    # Owner connection for Alembic, read only by the GitHub deploy workflow.
    # Deliberately NOT named "NCSM-Migration-Database-Url": app.py would load
    # that name into the running app, which must never hold owner rights.
    "postgres-owner-url" = "postgresql+psycopg://${urlencode(var.postgres_admin_username)}:${urlencode(var.postgres_admin_password)}@${local.pg_host}:5432/${local.pg_db}?sslmode=require"
  }
}

resource "azurerm_key_vault_secret" "app_loaded" {
  for_each     = nonsensitive(toset(keys(local.app_loaded_secrets)))
  name         = each.key
  key_vault_id = azurerm_key_vault.main.id
  value        = local.app_loaded_secrets[each.key]
  depends_on   = [time_sleep.wait_for_kv_rbac]
}

resource "azurerm_key_vault_secret" "referenced" {
  for_each     = nonsensitive(toset(keys(local.referenced_secrets)))
  name         = each.key
  key_vault_id = azurerm_key_vault.main.id
  value        = local.referenced_secrets[each.key]
  depends_on   = [time_sleep.wait_for_kv_rbac]
}

# Issued by Entra, so set out-of-band like the GKash keys:
#   az keyvault secret set --vault-name <kv> -n NCSM-Entra-Client-Secret --value ...
resource "azurerm_key_vault_secret" "entra_client_secret" {
  name         = "NCSM-Entra-Client-Secret"
  key_vault_id = azurerm_key_vault.main.id
  value        = "CHANGEME-set-from-entra-app-registration"
  depends_on   = [time_sleep.wait_for_kv_rbac]

  lifecycle {
    ignore_changes = [value]
  }
}

locals {
  public_host   = azurerm_cdn_frontdoor_endpoint.main.host_name
  public_origin = "https://${local.public_host}"

  kv_ref = { for k, v in azurerm_key_vault_secret.referenced : k => "@Microsoft.KeyVault(SecretUri=${v.versionless_id})" }

  # Shared by web and worker: the worker imports app.py, which validates the
  # full production configuration at import time.
  app_settings_common = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE"   = "false"
    "WEBSITES_PORT"                         = "5000"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.main.connection_string

    "APP_ENV"                 = "production"
    "FORCE_HTTPS"             = "1"
    "SESSION_COOKIE_SECURE"   = "1"
    "CSP_ENFORCE"             = "1"
    "CSP_REPORT_ONLY"         = "0"
    "AUDIT_VERIFY_ON_STARTUP" = "1"
    "AUDIT_FAIL_CLOSED"       = "1"
    "REQUIRE_ADMIN_MFA"       = "true"
    "MAIL_BACKEND"            = "disabled"
    "RATE_LIMIT_NAMESPACE"    = "production"

    # Front Door -> App Service front end -> gunicorn (docs/DEPLOYMENT.md).
    "TRUSTED_PROXY_HOPS"      = "2"
    "ALLOWED_HOSTS"           = local.public_host
    "CANONICAL_PUBLIC_ORIGIN" = local.public_origin
    "PUBLIC_BASE_URL"         = local.public_origin
    "ENFORCE_CANONICAL_HOST"  = "true"

    "KEY_VAULT_URL"       = azurerm_key_vault.main.vault_uri
    "DATABASE_URL"        = local.kv_ref["app-database-url"]
    "REDIS_URL"           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.redis_connection_string.versionless_id})"
    "PII_ENCRYPTION_KEY"  = local.kv_ref["pii-encryption-key"]
    "RATE_LIMIT_HMAC_KEY" = local.kv_ref["rate-limit-hmac-key"]

    # Managed identity + Storage Blob Data Owner (needs blob index tags).
    "BLOB_STORAGE_PROVIDER"     = "azure"
    "AZURE_STORAGE_ACCOUNT_URL" = azurerm_storage_account.main.primary_blob_endpoint
    "AZURE_BLOB_CONTAINER"      = azurerm_storage_container.product_images.name

    "GKASH_API_BASE_URL"  = var.gkash_api_base_url
    "GKASH_CID"           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.gkash_merchant_key.versionless_id})"
    "GKASH_SIGNATURE_KEY" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.gkash_secret_key.versionless_id})"

    "ENTRA_TENANT_ID" = var.entra_tenant_id
    "ENTRA_CLIENT_ID" = var.entra_client_id
  }
}
