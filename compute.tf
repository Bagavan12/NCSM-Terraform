############################################
# Phase 1 Step 1 / Step 4 — Container Registry
# SKU: Basic, +10GB extra storage
############################################

resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"

  # No admin user: Web/Worker apps pull images via their managed identity +
  # the AcrPull role assignment in security.tf, not a shared admin password.
  admin_enabled = false

  tags = local.common_tags
}

############################################
# Phase 1 Step 4 — App Service Plan
# SKU: Basic B2 (2 vCPU / 3.5GB RAM)
############################################

resource "azurerm_service_plan" "main" {
  name                = "asp-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku

  tags = local.common_tags
}

############################################
# Web App — customer-facing storefront
############################################

resource "azurerm_linux_web_app" "web" {
  name                = "app-${local.name_suffix}-web"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on = true

    application_stack {
      docker_image_name   = var.web_app_docker_image
      docker_registry_url = "https://${azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true
    health_check_path                       = "/health/live"
    health_check_eviction_time_in_min       = 5

    # Locked down to Azure Front Door only — see frontdoor.tf. Direct
    # *.azurewebsites.net access is blocked so traffic can't bypass the WAF.
    ip_restriction_default_action = "Deny"

    ip_restriction {
      name        = "AllowFrontDoor"
      priority    = 100
      action      = "Allow"
      service_tag = "AzureFrontDoor.Backend"
      headers {
        x_azure_fdid = [azurerm_cdn_frontdoor_profile.main.resource_guid]
      }
    }
  }

  app_settings = local.app_settings_common

  # @Microsoft.KeyVault(...) references above resolve using this app's own
  # system-assigned identity — it already holds "Key Vault Secrets User"
  # (see security.tf), so no key_vault_reference_identity_id override is needed.

  logs {
    application_logs {
      file_system_level = "Information"
    }
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  tags = local.common_tags

  # The image tag is owned by the GitHub deploy workflow, not Terraform.
  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }
}

############################################
# Worker App — background jobs (order processing, email, etc.)
# Same plan as the Web App to keep cost down; split onto its own
# azurerm_service_plan later if the workload needs isolating.
############################################

resource "azurerm_linux_web_app" "worker" {
  name                = "app-${local.name_suffix}-worker"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on = true

    application_stack {
      docker_image_name   = var.worker_app_docker_image
      docker_registry_url = "https://${azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true

    # App Service restarts a container that never answers on WEBSITES_PORT, and
    # an RQ worker serves no HTTP. A throwaway listener on an empty directory
    # satisfies the probe; the deny-all ip_restriction keeps it unreachable.
    app_command_line = "sh -c 'mkdir -p /tmp/probe && python -m http.server 5000 --directory /tmp/probe >/dev/null 2>&1 & exec rq worker --url \"$REDIS_URL\" ncsm'"

    # Worker has no public purpose — deny everything, including Front Door.
    ip_restriction_default_action = "Deny"
  }

  app_settings = merge(local.app_settings_common, {
    "PROCESS_ROLE" = "worker"
  })

  logs {
    application_logs {
      file_system_level = "Information"
    }
  }

  tags = local.common_tags

  # The image tag is owned by the GitHub deploy workflow, not Terraform.
  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }
}
