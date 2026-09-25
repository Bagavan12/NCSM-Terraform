# NCSM Store — Azure Infrastructure (Terraform)

Deploys the **Full Production Tier** from the NCSM Store proposal — the
tier marked "Recommended," matching the production architecture end-to-end
(~$157/mo). To deploy the cheaper **Essential Infrastructure** tier instead
(~$61/mo, no CDN/WAF/Redis/Defender — fine for a pilot, not for donation-
campaign traffic), comment out `frontdoor.tf`'s WAF/Front Door resources,
remove the Redis block in `data.tf`, and drop the Web App's `ip_restriction`
block (it depends on Front Door existing).

## How it is run

```sh
az login                                   # an account with Contributor + User Access Administrator
export TF_VAR_postgres_admin_password=...  # the only secret input
terraform init                             # state is remote, see below
terraform plan -out=tfplan
terraform apply tfplan
```

Non-secret inputs are committed in `prod.auto.tfvars`. There is no local
`terraform.tfvars`.

**State** lives in `sttfstatencsmytsr/tfstate/ncsm-store.tfstate` in
`rg-ncsm-store-tfstate` (versioned, soft delete, `CanNotDelete` lock). That
resource group was created once by hand and is not managed here.

**App deployment** is separate: `.github/workflows/deploy.yml` in the
application repository (elanncsm912/NCSM-STORE) builds the image, runs DB roles
and Alembic, and rolls the App Services. It signs in to Azure with GitHub OIDC
via the Entra app `github-ncsm-store-deploy`, and reads names from that repo's
Actions variables.

**Secrets**: the app's encryption keys and DB role passwords are generated in
`app_config.tf` straight into Key Vault. Externally issued values are set in
Key Vault by hand and never overwritten by Terraform:
`gkash-merchant-key` (→ `GKASH_CID`), `gkash-secret-key` (→ `GKASH_SIGNATURE_KEY`),
`NCSM-Entra-Client-Secret`.

## What this creates

| Category | Resource | SKU |
|---|---|---|
| Compute | App Service Plan | Basic B2 (2 vCPU / 3.5GB) |
| Compute | Web App + Worker App | Linux containers, system-assigned identity |
| Registry | Container Registry | Basic, no admin user |
| Database | PostgreSQL Flexible Server | Burstable B1MS, 32GB, 7-day PITR |
| Cache | Azure Managed Redis | Balanced B0 (HA) |
| Storage | Storage Account + Blob container | Hot, LRS, versioning + soft delete on |
| Secrets | Key Vault | Standard, RBAC-authorized |
| Edge | Front Door + WAF | Standard, Prevention mode |
| Backup | Data Protection vault (Blob) | LRS, 30-day operational retention |
| Observability | Log Analytics + App Insights | PerGB2018, 30-day retention |
| Governance | Budget alert (80%/100%) | — |
| Governance | Defender for Cloud | Off by default — see below |

Matches the six steps on the proposal's Implementation Scope slide and the
architecture in the pricing slide.

## Prerequisites

1. **Terraform** >= 1.7 and the **Azure CLI**.
2. Logged in with an account that has **Contributor + User Access
   Administrator** (or Owner) on the target subscription — the role
   assignments in `security.tf` need the second one.
   ```bash
   az login
   az account set --subscription "<NCSM subscription id>"
   ```
3. Terraform picks up the subscription/tenant from your `az login` session
   automatically. For CI, set `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`,
   `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET` (or `ARM_USE_OIDC`) instead.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set postgres_admin_password and alert_email

terraform init
terraform plan
terraform apply
```

First apply takes 15–25 minutes — Front Door, PostgreSQL, and Redis are the
slow ones.

## Who provisions vs. who configures

Per the proposal: **NCSM provisions the subscription and owns billing**
(they run this Terraform, or hand subscription Contributor access to
whoever does). **Bavion/the engineer configures the application on top** —
none of that is in this module:

- Alembic migrations against `postgres_connection_string`
- Building the Docker image and pushing it to the ACR this module creates
  (`terraform output acr_login_server`), then updating
  `web_app_docker_image` / `worker_app_docker_image` and re-applying
- Populating the real GKash and SMTP secrets (blank placeholders are written
  on first apply so the module doesn't block on them):
  ```bash
  az keyvault secret set --vault-name <key_vault_name> \
    --name gkash-merchant-key --value "<real value>"
  ```
- CORS configuration and GKash sandbox → production cutover
- Binding NCSM's real domain to Front Door (see the note at the bottom of
  `frontdoor.tf` — this needs a DNS TXT record from NCSM first, so it isn't
  automated here)

## Notes on specific choices

- **No ACR admin user, no App Service publish-profile secrets.** Both apps
  pull images and read Key Vault secrets through their own system-assigned
  managed identity. Nothing sensitive is duplicated into `app_settings` in
  plaintext — everything routes through `@Microsoft.KeyVault(...)` references.
- **Web App is only reachable through Front Door.** `ip_restriction` on the
  Web App denies everything except Front Door's backend service tag +
  matching `X-Azure-FDID` header, so the WAF can't be bypassed by hitting
  `*.azurewebsites.net` directly.
- **PostgreSQL backup vs. Blob backup are different mechanisms.** Postgres
  Flexible Server has built-in point-in-time-restore (`backup_retention_days`
  in `data.tf`) — no separate vault needed. Blob Storage backup uses a real
  Azure Backup vault (`backup.tf`) since the proposal prices it as its own
  line item.
- **Defender for Cloud defaults to off.** Its pricing tiers apply to the
  *entire subscription*, not just this resource group. If NCSM runs other
  workloads on the same subscription, confirm with their Azure admin before
  setting `enable_defender_for_cloud = true`.
- **`time_sleep` resources** absorb Azure RBAC's propagation delay (role
  assignment → usable can take up to ~30s) so a fresh `apply` doesn't fail
  on Key Vault secret writes or the Blob backup instance. If you still hit a
  403 on first apply, just `terraform apply` again — it's idempotent.
- **State file**: for anything beyond a single operator, uncomment the
  `backend "azurerm"` block in `providers.tf` and point it at a storage
  account (create that one manually first — don't manage your own state
  backend's storage account with the same state it holds).

## Estimated monthly cost

~$157/mo USD (≈RM 636 at the proposal's indicative FX), billed directly by
Microsoft to NCSM — separate from Bavion's one-time RM6,000 professional
services fee. Budget alert fires at 80% actual and 100% forecasted spend to
the `alert_email` you set.
