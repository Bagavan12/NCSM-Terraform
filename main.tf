############################################
# Phase 1 Step 1 — Architecture & Subscription Setup
############################################

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = local.common_tags
}

############################################
# Budget alert — NCSM is billed directly by Microsoft for all of this,
# so they get warned before the monthly spend runs away.
############################################

resource "azurerm_consumption_budget_resource_group" "main" {
  name              = "budget-${local.name_suffix}"
  resource_group_id = azurerm_resource_group.main.id

  amount     = var.budget_amount_usd
  time_grain = "Monthly"

  # Fixed, not derived from timestamp() — a dynamic start_date would show as
  # a perpetual diff on every `plan` since it re-evaluates on every run.
  # Azure re-baselines a Monthly budget automatically each period; this only
  # anchors when tracking begins.
  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}

############################################
# Defender for Cloud — subscription-wide, off by default. See variables.tf.
############################################

resource "azurerm_security_center_subscription_pricing" "app_services" {
  count         = var.enable_defender_for_cloud ? 1 : 0
  tier          = "Standard"
  resource_type = "AppServices"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  count         = var.enable_defender_for_cloud ? 1 : 0
  tier          = "Standard"
  resource_type = "StorageAccounts"
}

resource "azurerm_security_center_subscription_pricing" "key_vaults" {
  count         = var.enable_defender_for_cloud ? 1 : 0
  tier          = "Standard"
  resource_type = "KeyVaults"
}
