# NCSM Store — Deployment Runbook

Step-by-step instructions to deploy this Terraform module against NCSM's
real Azure subscription. Read `README.md` first for the architecture
overview — this file is just the ordered checklist to actually run it.

---

## 0. Before you start

Confirm your tools are installed and recent enough:

```bash
terraform version   # needs >= 1.7.0
az version           # any recent az cli
```

You'll need an Azure account with **Contributor + User Access
Administrator** (or Owner) on NCSM's subscription — `security.tf` creates
role assignments, which needs the second one specifically. Without it,
`apply` will fail partway through with 403s.

---

## 1. Log into NCSM's subscription (not your own)

```bash
az login
az account list --output table     # find NCSM's subscription in the list
az account set --subscription "<NCSM subscription id or name>"
az account show                    # CONFIRM this shows NCSM's subscription/tenant
```

**Do not skip the `az account show` confirmation.** If this still shows
your own subscription, everything below will deploy into the wrong place.

---

## 2. Set up your variables file

```bash
cd ncsm-terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in, at minimum:

| Variable | What to put |
|---|---|
| `postgres_admin_password` | A strong generated password (not the placeholder). Save it somewhere safe (password manager) — you'll need it if you ever connect directly with `psql`. |
| `alert_email` | NCSM's real ops/admin email — this is where budget alerts go. |
| `budget_start_date` | First of the current or next month, RFC3339, e.g. `"2026-10-01T00:00:00Z"`. Must not be in the past. |

Leave these blank for now — they deploy fine as placeholders and get filled
in later (Step 6):

- `gkash_merchant_key`, `gkash_secret_key`
- `smtp_username`, `smtp_password`
- `web_app_docker_image`, `worker_app_docker_image`

**Never commit `terraform.tfvars`.** It's not currently in a `.gitignore`
in this folder — if you turn this into a git repo, add `terraform.tfvars`,
`*.tfstate*`, and `.terraform/` to `.gitignore` before your first commit.

---

## 3. (Recommended for anything beyond a single laptop) Set up remote state

By default Terraform keeps its state file (`terraform.tfstate`) on local
disk — and that file contains **plaintext secrets** (the Postgres password,
storage account keys, Redis key). For a real customer deployment, do this
once before your first `apply`:

1. Manually create a small storage account for state (don't manage this
   storage account's own state with itself):
   ```bash
   az group create -n rg-terraform-state -l malaysiawest
   az storage account create -n sttfstatencsm -g rg-terraform-state \
     -l malaysiawest --sku Standard_LRS
   az storage container create -n tfstate --account-name sttfstatencsm
   ```
2. Uncomment the `backend "azurerm"` block in `providers.tf`.
3. Run `terraform init` again — it will offer to migrate your local state
   into the new backend. Say yes.

If you're just doing a one-off solo deployment, you can skip this and stay
on local state — just guard `terraform.tfstate` like a secrets file.

---

## 4. Initialize and validate

```bash
terraform init
terraform validate
```

`validate` should say `Success!` (it may show a couple of harmless
deprecation warnings about the `metric` block in `monitoring.tf` — safe to
ignore on the current provider version).

---

## 5. Plan, then review before applying

```bash
terraform plan -out=tfplan
```

Read the plan output. You're looking for:

- **Resource count** — should be creating everything fresh (~47 resources)
  if this is a brand-new environment, 0 destroyed.
- **No errors.** If you see an error, stop and fix it before continuing —
  don't `apply` a plan that errored.
- Anything under "Plan: X to add, Y to change, Z to destroy" where
  `destroy` is non-zero, on what should be a first-time apply — that's a
  sign something is wrong (e.g. you're pointed at the wrong subscription
  and Terraform thinks existing resources need replacing).

When it looks right:

```bash
terraform apply tfplan
```

First apply takes **15–25 minutes** — Front Door, PostgreSQL, and Redis are
the slow ones. It's normal to wait.

**If you hit a 403 on a Key Vault secret or the Blob backup instance on the
very first apply:** this is a known Azure RBAC propagation delay. Just run
`terraform apply` again (no plan file needed this time) — it's idempotent
and will pick up where it left off.

---

## 6. Post-apply: application configuration (not automated by this module)

Per the proposal, Terraform provisions the infrastructure; a separate
engineer configures the application on top. Do these after infrastructure
is up:

### 6a. Build and push the real Docker images

```bash
terraform output acr_login_server
az acr login --name <acr name from above, without .azurecr.io>

docker build -t <acr_login_server>/ncsm-store-web:latest ./web
docker push <acr_login_server>/ncsm-store-web:latest

docker build -t <acr_login_server>/ncsm-store-worker:latest ./worker
docker push <acr_login_server>/ncsm-store-worker:latest
```

Then update `web_app_docker_image` / `worker_app_docker_image` in
`terraform.tfvars` to point at the real tags, and re-apply:

```bash
terraform apply
```

### 6b. Set the real GKash and SMTP secrets

```bash
terraform output key_vault_name

az keyvault secret set --vault-name <key_vault_name> \
  --name gkash-merchant-key --value "<real value>"
az keyvault secret set --vault-name <key_vault_name> \
  --name gkash-secret-key --value "<real value>"
az keyvault secret set --vault-name <key_vault_name> \
  --name smtp-username --value "<real value>"
az keyvault secret set --vault-name <key_vault_name> \
  --name smtp-password --value "<real value>"
```

These are set directly via `az keyvault secret set`, not through Terraform
— the module deliberately ignores changes to these values so a manual
portal/CLI update never gets clobbered by the next `apply`.

### 6c. Run database migrations

```bash
terraform output postgres_fqdn
# use the postgres_connection_string secret in Key Vault, or connect with
# the admin credentials from terraform.tfvars, then:
alembic upgrade head
```

If you need direct `psql` access for this, set `allowed_admin_ip` in
`terraform.tfvars` to your IP and re-apply first.

### 6d. Bind NCSM's real domain

This needs an interactive DNS step with NCSM, so it's not automated. See
the note at the bottom of `frontdoor.tf`:

1. `az afd custom-domain create ...` (or add an
   `azurerm_cdn_frontdoor_custom_domain` resource)
2. Give NCSM the validation TXT record to publish on their DNS
3. Point their domain's CNAME at `terraform output front_door_endpoint_hostname`
4. Re-run `terraform apply` with the custom domain resource added

### 6e. CORS + GKash sandbox → production cutover

Handled in application config, not this Terraform module.

---

## 7. Verify

```bash
terraform output web_app_public_url
```

Open that URL — it should route through Front Door + WAF. The direct
`*.azurewebsites.net` hostname (`terraform output web_app_direct_hostname`)
should **not** be publicly reachable — that's intentional (see
`README.md`'s "Web App is only reachable through Front Door" note).

Check `terraform output` for everything else you'll need (ACR login
server, Key Vault name, Postgres FQDN, Redis hostname, storage account
name, Log Analytics workspace ID).

---

## 8. Ongoing

- Budget alerts fire at 80% actual / 100% forecasted spend to `alert_email`.
- To change anything, edit `.tf` files or `terraform.tfvars`, then
  `terraform plan` → review → `terraform apply` again. Never hand-edit
  resources in the Azure portal if you can help it — it'll cause Terraform
  to show unexpected diffs next time.
- If NCSM asks about Defender for Cloud: it's off by default because it's
  billed at the **subscription level**, not scoped to this resource group.
  Only set `enable_defender_for_cloud = true` after confirming with their
  Azure admin that nothing else on the subscription would be affected.
