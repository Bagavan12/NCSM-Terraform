############################################
# Phase 1 Step 5 — Azure Front Door + WAF
# SKU: Standard_AzureFrontDoor
############################################

resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "afd-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard_AzureFrontDoor"

  tags = local.common_tags
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "fde-${local.name_suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = local.common_tags
}

resource "azurerm_cdn_frontdoor_origin_group" "web" {
  name                     = "og-web"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/health"
    request_type        = "GET"
    protocol            = "Https"
    interval_in_seconds = 30
  }
}

resource "azurerm_cdn_frontdoor_origin" "web" {
  name                          = "origin-web"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.web.id

  enabled                        = true
  host_name                      = azurerm_linux_web_app.web.default_hostname
  origin_host_header             = azurerm_linux_web_app.web.default_hostname
  http_port                      = 80
  https_port                     = 443
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_route" "web" {
  name                          = "route-web"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.web.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.web.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
}

############################################
# WAF — Prevention mode, custom rules.
#
# Microsoft's managed rule sets (Microsoft_DefaultRuleSet / BotManagerRuleSet)
# only work on the Premium_AzureFrontDoor SKU — this profile is on Standard
# (see frontdoor.tf's profile block) to match the proposal's ~$157/mo
# estimate, so we hand-write a minimal custom rule set instead: a per-client
# rate limit plus signature blocks for the most common SQLi/XSS payloads in
# the query string and POST body. This is NOT equivalent coverage to
# Microsoft's managed OWASP CRS — if NCSM later needs that level of
# protection (e.g. a compliance requirement), upgrade the profile SKU to
# Premium_AzureFrontDoor and swap this policy back to `managed_rule` blocks.
############################################

resource "azurerm_cdn_frontdoor_firewall_policy" "main" {
  name                = "waf${replace(local.name_suffix, "-", "")}"
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = azurerm_cdn_frontdoor_profile.main.sku_name
  enabled             = true
  mode                = "Prevention"

  custom_rule {
    name                           = "RateLimitPerClient"
    enabled                        = true
    priority                       = 100
    type                           = "RateLimitRule"
    action                         = "Block"
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 300

    match_condition {
      # Match all traffic. "Any" would be simpler, but the provider requires
      # match_values and Azure rejects match_values with "Any".
      match_variable = "RemoteAddr"
      operator       = "IPMatch"
      match_values   = ["0.0.0.0/0", "::/0"]
    }
  }

  custom_rule {
    name     = "BlockSQLiQueryString"
    enabled  = true
    priority = 200
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "QueryString"
      operator           = "RegEx"
      negation_condition = false
      transforms         = ["Lowercase", "UrlDecode"]
      match_values       = ["(union\\s+select)|(select\\s+.{1,100}\\s+from)|(drop\\s+table)|(insert\\s+into)|('\\s*or\\s*'?1'?\\s*=\\s*'?1)|(;--)|(\\bexec(\\s|\\+)+(s|x)p\\w+)"]
    }
  }

  custom_rule {
    name     = "BlockSQLiRequestBody"
    enabled  = true
    priority = 210
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "RequestBody"
      operator           = "RegEx"
      negation_condition = false
      transforms         = ["Lowercase", "UrlDecode"]
      match_values       = ["(union\\s+select)|(select\\s+.{1,100}\\s+from)|(drop\\s+table)|(insert\\s+into)|('\\s*or\\s*'?1'?\\s*=\\s*'?1)|(;--)|(\\bexec(\\s|\\+)+(s|x)p\\w+)"]
    }
  }

  custom_rule {
    name     = "BlockXSSQueryString"
    enabled  = true
    priority = 300
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "QueryString"
      operator           = "RegEx"
      negation_condition = false
      transforms         = ["Lowercase", "UrlDecode"]
      match_values       = ["(<script)|(javascript:)|(onerror\\s*=)|(onload\\s*=)|(<iframe)|(document\\.cookie)|(alert\\()"]
    }
  }

  custom_rule {
    name     = "BlockXSSRequestBody"
    enabled  = true
    priority = 310
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "RequestBody"
      operator           = "RegEx"
      negation_condition = false
      transforms         = ["Lowercase", "UrlDecode"]
      match_values       = ["(<script)|(javascript:)|(onerror\\s*=)|(onload\\s*=)|(<iframe)|(document\\.cookie)|(alert\\()"]
    }
  }

  tags = local.common_tags
}

resource "azurerm_cdn_frontdoor_security_policy" "main" {
  name                     = "secpol-${local.name_suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.main.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.main.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

# NOTE — custom domain + SSL binding (e.g. store.ncsm.org.my) is deliberately
# not automated here: it requires NCSM to create a DNS CNAME/TXT validation
# record before Terraform can provision the domain resource, which is an
# interactive step. Do this once Front Door is live:
#   1. az afd custom-domain create ... (or azurerm_cdn_frontdoor_custom_domain)
#   2. Give NCSM the validation TXT record to publish
#   3. Point their domain's CNAME at azurerm_cdn_frontdoor_endpoint.main.host_name
#   4. Re-run terraform apply with the custom domain resource added
