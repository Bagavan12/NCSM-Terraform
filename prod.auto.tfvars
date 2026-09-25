# Non-secret inputs, committed. The one secret input, postgres_admin_password,
# comes from the TF_VAR_postgres_admin_password GitHub secret. Application
# secrets are generated in app_config.tf or set directly in Key Vault.

project_name = "ncsm-store"
environment  = "prod"
location     = "malaysiawest"

postgres_admin_username = "ncsmadmin"

alert_email       = "sathishkumar@cancer.org.my"
budget_amount_usd = 180
budget_start_date = "2026-10-01T00:00:00Z"

allowed_admin_ip          = ""
enable_defender_for_cloud = false

# Admin sign-in (Entra app registration)
entra_tenant_id = "8680425b-26fd-4998-a846-557cb0328fc3"
entra_client_id = "5187fcbb-00fa-46d1-9f69-e00c4e66e51e"

# GKash sandbox until go-live
gkash_api_base_url = "https://api-staging.pay.asia"

# sathishkumar@cancer.org.my keeps Key Vault secret access
key_vault_admin_object_ids = ["43168f21-3466-47a8-aad6-c03d7fbefffd"]
