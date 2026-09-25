############################################
# Naming & Environment
############################################

variable "project_name" {
  description = "Short project identifier used in resource names."
  type        = string
  default     = "ncsm-store"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region. Malaysia West is the region used in the NCSM proposal pricing."
  type        = string
  default     = "malaysiawest"
}

variable "tags" {
  description = "Extra tags merged onto every resource (Project/Environment/ManagedBy are added automatically)."
  type        = map(string)
  default     = {}
}

############################################
# PostgreSQL Flexible Server
# Proposal SKU: Burstable B1MS, 32GB SSD
############################################

variable "postgres_admin_username" {
  description = "PostgreSQL Flexible Server administrator login."
  type        = string
  default     = "ncsmadmin"
}

variable "postgres_admin_password" {
  description = "PostgreSQL Flexible Server administrator password. Supply via terraform.tfvars or TF_VAR_postgres_admin_password — never commit it."
  type        = string
  sensitive   = true
}

variable "postgres_sku_name" {
  description = "Flexible Server compute SKU. B_Standard_B1ms = Burstable B1MS from the proposal."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Storage size in MB. 32768 = 32GB from the proposal."
  type        = number
  default     = 32768
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "postgres_backup_retention_days" {
  description = "Native point-in-time-restore window (the deck's '7-day PITR')."
  type        = number
  default     = 7
}

variable "allowed_admin_ip" {
  description = "Optional single IP (e.g. the engineer doing migrations) allowed to reach PostgreSQL directly. Leave empty to skip — App Service still reaches it via the 'Allow Azure services' rule."
  type        = string
  default     = ""
}

############################################
# Azure Managed Redis — Balanced B0
############################################

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest; replaces the retired Standard C0."
  type        = string
  default     = "Balanced_B0"
}

############################################
# App Service — Basic B2 plan, Web + Worker apps
############################################

variable "app_service_sku" {
  description = "Basic B2 = 2 vCPU / 3.5GB RAM, matching the proposal."
  type        = string
  default     = "B2"
}

variable "web_app_docker_image" {
  description = "Image:tag for the Web App, e.g. 'ncsm-store-web:latest'. Placeholder until CI pushes the real image to ACR."
  type        = string
  default     = "mcr.microsoft.com/appsvc/staticsite:latest"
}

variable "worker_app_docker_image" {
  description = "Image:tag for the Worker App. Placeholder until CI pushes the real image to ACR."
  type        = string
  default     = "mcr.microsoft.com/appsvc/staticsite:latest"
}

############################################
# Secrets — stored in Key Vault, never in state as app_settings
############################################

variable "gkash_merchant_key" {
  description = "GKash merchant/API key. Leave blank to deploy with a placeholder and fill in via Key Vault later."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gkash_secret_key" {
  description = "GKash secret/signing key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "smtp_username" {
  type      = string
  sensitive = true
  default   = ""
}

variable "smtp_password" {
  type      = string
  sensitive = true
  default   = ""
}

############################################
# Monitoring, Budget, Defender
############################################

variable "alert_email" {
  description = "Email address for budget alerts (required)."
  type        = string
}

variable "budget_amount_usd" {
  description = "Monthly budget threshold in USD. Full Production Tier estimate is ~$157/mo; default gives headroom."
  type        = number
  default     = 180
}

variable "budget_start_date" {
  description = "First-of-month UTC timestamp when budget tracking begins, RFC3339 (e.g. \"2026-10-01T00:00:00Z\"). Must not be in the past relative to when you first apply."
  type        = string
}

variable "enable_defender_for_cloud" {
  description = <<-EOT
    Microsoft Defender for Cloud plans are enabled AT THE SUBSCRIPTION LEVEL,
    not scoped to this resource group. If NCSM runs other workloads on the
    same subscription, confirm with their Azure admin before setting this to
    true, since it changes billing/protection for everything in the sub.
  EOT
  type        = bool
  default     = false
}

############################################
# Application identity / payments / access
############################################

variable "entra_tenant_id" {
  description = "Tenant of the Entra app registration used for admin sign-in."
  type        = string
}

variable "entra_client_id" {
  description = "Client ID of the Entra app registration used for admin sign-in. Its secret goes in Key Vault as NCSM-Entra-Client-Secret."
  type        = string
}

variable "gkash_api_base_url" {
  description = "GKash API origin. Sandbox is https://api-staging.pay.asia; switch to the live host before go-live."
  type        = string
  default     = "https://api-staging.pay.asia"
}

variable "key_vault_admin_object_ids" {
  description = "Entra object IDs (people or groups) that keep Key Vault Secrets Officer regardless of who runs apply."
  type        = list(string)
  default     = []
}
