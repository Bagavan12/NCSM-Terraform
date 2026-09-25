output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "web_app_public_url" {
  description = "Public URL customers should use — routed through Front Door + WAF."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}"
}

output "web_app_direct_hostname" {
  description = "Direct App Service hostname. Locked down to Front Door only — not for public use."
  value       = azurerm_linux_web_app.web.default_hostname
}

output "worker_app_name" {
  value = azurerm_linux_web_app.worker.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "redis_hostname" {
  value = azurerm_managed_redis.main.hostname
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "front_door_endpoint_hostname" {
  description = "CNAME target for NCSM's custom domain once they're ready to bind one."
  value       = azurerm_cdn_frontdoor_endpoint.main.host_name
}
