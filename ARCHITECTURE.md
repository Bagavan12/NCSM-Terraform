# NCSM Store — Code Walkthrough

This explains what every file in this Terraform module does and *why* it's
built the way it is, so you can walk someone else through it. It pairs
with `README.md` (the reference doc) and `RUNBOOK.md` (the run-it
checklist) — this one is for understanding the code itself.

---

## The big picture

This is a Terraform module that provisions **all the Azure infrastructure**
for an e-commerce/donation storefront (NCSM Store) — compute, database,
cache, storage, secrets, edge/CDN+WAF, backup, and monitoring. It does
**not** deploy application code — it builds the empty house; a separate
step (documented in `RUNBOOK.md` step 6) pushes the actual Docker images
and app secrets into it.

Every `.tf` file is loaded together by Terraform — the split into multiple
files is purely organizational (Terraform doesn't care about filenames),
grouped by concern:

| File | Concern |
|---|---|
| `providers.tf` | Terraform/provider setup, state backend |
| `variables.tf` | All configurable inputs |
| `locals.tf` | Computed names/tags shared across resources |
| `main.tf` | Resource group, Log Analytics, budget, Defender |
| `data.tf` | PostgreSQL, Redis, Storage account |
| `compute.tf` | Container Registry, App Service Plan, Web + Worker apps |
| `security.tf` | Key Vault, secrets, all RBAC role assignments |
| `frontdoor.tf` | Front Door CDN + WAF |
| `backup.tf` | Blob storage backup vault |
| `monitoring.tf` | Diagnostic settings → Log Analytics |
| `outputs.tf` | Values printed after `apply` (URLs, names, IDs) |

---

## `providers.tf` — the foundation

Declares which Terraform version and providers this needs:
`azurerm` (the actual Azure resources), `random` (unique name suffixes),
`time` (RBAC propagation delays — see below).

The `backend "azurerm"` block is **commented out** by default, meaning
state lives on local disk. It's there so you can switch to shared remote
state (a storage account) once more than one person needs to run this —
see `RUNBOOK.md` step 3.

`data "azurerm_client_config" "current"` reads who's currently logged in
via `az login` — used later in `security.tf` to grant that identity
permission to write Key Vault secrets during `apply`.

---

## `variables.tf` — the knobs

Every input the module accepts, with defaults matching the proposal's
"Full Production Tier" SKUs. Two categories worth knowing:

- **No default, must be supplied**: `postgres_admin_password`,
  `alert_email`, `budget_start_date`. Terraform will refuse to plan/apply
  without these.
- **Secrets with a blank default** (`gkash_merchant_key`,
  `gkash_secret_key`, `smtp_username`, `smtp_password`): safe to leave
  blank on first apply. The module writes placeholder values to Key Vault
  instead of blocking, and real values get set later via `az keyvault
  secret set` — see `security.tf`'s `lifecycle { ignore_changes = [value]
  }` blocks, which stop a later `apply` from wiping out a manually-set
  secret.

---

## `locals.tf` — naming

Azure requires some resource names to be **globally unique** across all of
Azure (Storage Account, Container Registry, Key Vault) and enforces
length/character limits on each. This file:

1. Generates a random 4-character suffix (`random_string.suffix`) so two
   deployments of this module never collide.
2. Builds each constrained name by stripping hyphens where the resource
   type disallows them, then truncating to the resource's max length with
   `substr(...)`.
3. Builds `common_tags`, merged onto every resource — `Project`,
   `Environment`, `ManagedBy = "Terraform"`, plus anything in `var.tags`.

If you ever need to explain "why does the storage account have a random
suffix in its name," this is why.

---

## `main.tf` — resource group, logging, budget, Defender

- **Resource group** — the container everything else lives in.
- **Log Analytics workspace + Application Insights** — the destination
  for logs/metrics from every other resource (wired up in
  `monitoring.tf`).
- **Budget alert** — fires at 80% *actual* spend and 100% *forecasted*
  spend to `alert_email`. The `start_date` is a fixed value (not
  `timestamp()`) deliberately — a dynamic timestamp would show as a
  perpetual diff on every `plan` even when nothing changed.
- **Defender for Cloud pricing tiers** — `count = var.enable_defender_for_cloud
  ? 1 : 0` means these three resources only get created if that variable
  is `true` (default `false`). Important: Defender pricing applies to the
  **whole subscription**, not just this resource group — that's why it
  defaults off and the variable's description warns about it.

---

## `data.tf` — PostgreSQL, Redis, Storage

**PostgreSQL Flexible Server** (Burstable B1MS):
- `backup_retention_days` gives native point-in-time-restore — no separate
  backup resource needed for this (unlike Blob, see `backup.tf`).
- `lifecycle { ignore_changes = [administrator_password] }` — so rotating
  the password later (e.g. via the portal or a separate secrets process)
  doesn't force Terraform to try to recreate the server.
- Two firewall rules: `AllowAzureServices` (the `0.0.0.0`–`0.0.0.0` range
  is Azure's special-cased "allow any Azure-hosted resource" rule — it
  does **not** open the server to the public internet, despite how it
  looks), and an optional `AllowAdminIP` for one named IP if
  `allowed_admin_ip` is set (e.g. so an engineer can `psql` in directly
  for migrations).

**Azure Managed Redis** (Balanced B0, high availability): replaces the
proposal's Azure Cache for Redis Standard C0, which Azure no longer allows
new deployments of. TLS-only (`client_protocol = "Encrypted"`, port 10000),
`EnterpriseCluster` policy so clients see a single endpoint, and access-key
auth enabled so the apps' `rediss://` connection string works.

**Storage Account**: `StorageV2`, Hot tier, LRS. Blob versioning + 30-day
soft-delete + point-in-time restore are all on (`restore_policy.days = 29`
must always be less than `delete_retention_policy.days = 30` — that's an
Azure API constraint, not a stylistic choice). One private container,
`product-images`.

---

## `compute.tf` — where the app actually runs

**Container Registry**: `admin_enabled = false` — no shared admin
password. Apps authenticate to pull images using their own identity
instead (see `security.tf`).

**App Service Plan**: one plan (Basic B2), shared by both the Web and
Worker apps — that's a deliberate cost decision noted in the file's
comment; split them onto separate plans later only if the workload needs
isolating.

**Web App** (customer-facing):
- `identity { type = "SystemAssigned" }` — Azure creates and manages a
  unique identity for this app automatically. This identity is how the app
  authenticates to Key Vault and ACR, with no passwords/secrets to leak.
- `ip_restriction_default_action = "Deny"` + a single `Allow` rule scoped
  to Front Door's service tag *and* a matching `X-Azure-FDID` header. This
  is the mechanism that makes "Web App is only reachable through Front
  Door" true — the header check specifically prevents someone from
  standing up their *own* Front Door profile and pointing it at your app
  to bypass the WAF, since only your specific Front Door instance's ID
  matches.
- Every sensitive `app_settings` value uses
  `@Microsoft.KeyVault(SecretUri=...)` syntax instead of a plaintext
  value — App Service resolves these at runtime using the app's own
  managed identity, so nothing sensitive is ever visible in the Azure
  portal's app settings blade or in Terraform state as a "real" secret
  (only the Key Vault *reference* is stored, not the value itself, in this
  particular field — though see the caveat in `RUNBOOK.md` about state
  files still containing other secrets).

**Worker App** (background jobs): same pattern, but
`ip_restriction_default_action = "Deny"` with **no** allow rule at all —
it has no public-facing purpose, so everything is blocked.

---

## `security.tf` — Key Vault and all the RBAC

**Key Vault**: `enable_rbac_authorization = true` means access is granted
via Azure role assignments (not the older "access policy" model).
`purge_protection_enabled = true` + 90-day soft-delete means a deleted
vault (or secret) is recoverable for 90 days — can't be permanently wiped
by accident.

**The `time_sleep` resources** exist because of a real, common Azure
gotcha: when Terraform grants itself "Key Vault Secrets Officer" so it can
write the secret placeholders, that role assignment takes up to ~30
seconds to actually propagate through Azure's backend. Writing a secret
immediately after would often 403. The `time_sleep` just waits 30s between
"role granted" and "now use that role," so a fresh `apply` doesn't
spuriously fail. Same pattern is used again in `backup.tf` for the backup
vault's storage permissions.

**Secret placeholders**: five `azurerm_key_vault_secret` resources are
created up front — Postgres connection string, Redis connection string,
Storage connection string (all built from other resources' real,
computed attributes), and GKash/SMTP secrets (which fall back to a
`CHANGEME` placeholder string if left blank in `terraform.tfvars`). The
`lifecycle { ignore_changes = [value] }` on the GKash/SMTP secrets is what
lets someone run `az keyvault secret set` by hand later without Terraform
silently reverting it back to `CHANGEME` on the next `apply`.

**Role assignments** (the bottom half of the file): each app identity gets
exactly the roles it needs and nothing more —
`AcrPull` (pull container images), `Key Vault Secrets User` (read secrets,
can't write/delete them), `Storage Blob Data Contributor` (read/write blob
data). This is the "least privilege" pattern — no identity in this whole
module holds a broad Owner/Contributor-equivalent role over application
data.

---

## `frontdoor.tf` — edge, CDN, WAF

**Front Door profile**: `Standard_AzureFrontDoor` SKU — chosen to match
the proposal's ~$157/mo cost estimate. This matters for the WAF section
below.

**Origin group + origin + route**: standard Front Door plumbing — defines
the Web App as the single backend origin, a health probe hitting `/health`
every 30s, and a route that forces HTTPS and redirects HTTP→HTTPS.

**WAF firewall policy — the one piece that needed fixing during testing**:
Azure's **managed** WAF rule sets (Microsoft's baseline OWASP rules,
`Microsoft_DefaultRuleSet`, plus `Microsoft_BotManagerRuleSet`) only work
on the **Premium** Front Door SKU. Since this profile is intentionally on
Standard (to hit the proposal's price point), the policy instead uses five
hand-written `custom_rule` blocks:

1. `RateLimitPerClient` — blocks a client IP sending more than 300
   requests/minute.
2. `BlockSQLiQueryString` / `BlockSQLiRequestBody` — regex-blocks common
   SQL-injection signatures (`union select`, `drop table`, `' or '1'='1`,
   etc.) in the URL query string and in POST bodies.
3. `BlockXSSQueryString` / `BlockXSSRequestBody` — same idea for common
   XSS payloads (`<script`, `javascript:`, `onerror=`, etc.).

**This is meaningfully lighter protection than Microsoft's managed rule
set** — it catches the obvious/common attack signatures, not the full
OWASP Core Rule Set's coverage. If NCSM later has a compliance requirement
that needs the full managed rule set, the fix is: upgrade the profile's
`sku_name` to `Premium_AzureFrontDoor` and swap these `custom_rule` blocks
back to `managed_rule` blocks. That's a real cost change (Premium adds
roughly $250–300/mo over Standard), which is why it isn't the default.

The trailing comment block documents binding NCSM's real domain — it's
deliberately left as a manual, documented step rather than automated,
because it requires an interactive DNS TXT record exchange with NCSM.

---

## `backup.tf` — Blob storage backup

PostgreSQL already has its own point-in-time-restore built into the
Flexible Server resource (`data.tf`) — no separate vault needed for that.
This file is *only* for Blob Storage, because the sales proposal prices
"Azure Backup" as its own distinct line item. It creates a Data Protection
vault, grants it `Storage Account Backup Contributor` on the storage
account (with the same `time_sleep` RBAC-propagation pattern as
`security.tf`), and configures a 30-day operational retention policy.

---

## `monitoring.tf` — wiring logs to Log Analytics

Four `azurerm_monitor_diagnostic_setting` resources — one each for the Web
App, Worker App, PostgreSQL server, and Key Vault — all pointing at the
same Log Analytics workspace from `main.tf`. Each selects specific log
categories relevant to that resource (HTTP/console/app logs for the web
apps, PostgreSQL logs, Key Vault audit events) plus `AllMetrics`.

One thing to know if you're maintaining this later: the `metric` block
used here is deprecated in favor of `enabled_metric` as of a recent
`azurerm` provider release — still works fine on the current `~> 4.0`
pin, but will need updating before upgrading to provider v5.

---

## `outputs.tf` — what you get back after `apply`

The values you actually need afterward: the public URL (through Front
Door — this is the one to give to NCSM/customers), the direct App Service
hostname (deliberately *not* public-facing, useful only for debugging),
ACR login server (for pushing images), Key Vault name/URI, Postgres FQDN,
Redis hostname, storage account name, and the Log Analytics workspace ID.
None of these outputs leak actual secret *values* — connection strings
with embedded passwords are never output directly, only resource
names/hostnames/URIs.

---

## The overall security model, in one paragraph

Nothing public-facing talks to the database, cache, or storage directly —
only the Web/Worker apps do, and only using their own per-app managed
identity (no shared passwords). The Web App itself is only reachable
through Front Door + WAF (verified by an origin header check, not just an
IP allowlist). Every secret lives in Key Vault, referenced by URI in app
settings rather than embedded as plaintext. The only broad access anyone
holds is the human running `terraform apply`, and only temporarily, to
provision the RBAC role assignments and initial Key Vault secrets — after
that, the running application's access is scoped tightly to exactly what
it needs.

---

## Estimated monthly cost (verified against live Azure pricing)

| Category | Item | ~Monthly |
|---|---|---|
| Fixed | App Service Plan B2 (Web + Worker share one) | $24.82 |
| Fixed | PostgreSQL B1MS compute | $17.08 |
| Fixed | PostgreSQL 32GB storage | $3.97 |
| Fixed | Azure Managed Redis Balanced B0 (HA, 2 × $0.018/h) | $26.28 |
| Fixed | Container Registry Basic | $5.00 |
| Fixed | Front Door Standard base fee | $35.00 |
| Fixed | WAF policy | $5.00 |
| Fixed | WAF custom rules (5 × $1) | $5.00 |
| Variable | Log Analytics + App Insights ingestion | $0–15 |
| Variable | Blob storage (product images) | $1–2 |
| Variable | Blob operational backup | $1–3 |
| Variable | Key Vault operations | <$1 |
| Variable | Front Door data transfer + requests | $5–15+ |
| **Total** | | **≈ $150–170/mo** |

Matches the proposal's ~$157/mo estimate. The variable rows scale up under
real traffic — worth calling out explicitly if NCSM asks "what happens to
cost during a donation campaign spike."
