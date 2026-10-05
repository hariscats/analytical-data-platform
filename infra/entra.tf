locals {
  identifier_uri = "api://${local.tenant_id}/${local.name}-imagery"

  # App role value => description. The value is also the DAB role name.
  app_roles = {
    "mission-a-analyst" = "Read Mission A scenes and spectra."
    "mission-b-analyst" = "Read Mission B scenes and spectra."
    "catalog-viewer"    = "Read the released scene catalog without coordinates or spectra."
  }

  # Demo client application => the one app role it is assigned.
  clients = {
    "analyst-a" = "mission-a-analyst"
    "analyst-b" = "mission-b-analyst"
    "catalog"   = "catalog-viewer"
  }
}

resource "random_uuid" "app_role" {
  for_each = local.app_roles
}

resource "azuread_application" "api" {
  display_name     = "${local.name}-imagery-api"
  identifier_uris  = [local.identifier_uri]
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg"

  api {
    # v2 tokens carry the issuer DAB and APIM validate.
    requested_access_token_version = 2
  }

  dynamic "app_role" {
    for_each = local.app_roles
    content {
      allowed_member_types = ["Application"]
      description          = app_role.value
      display_name         = app_role.key
      enabled              = true
      id                   = random_uuid.app_role[app_role.key].result
      value                = app_role.key
    }
  }
}

resource "azuread_service_principal" "api" {
  client_id = azuread_application.api.client_id
  owners    = [data.azuread_client_config.current.object_id]
  # Only clients holding an app role can obtain a token for this API.
  app_role_assignment_required = true
}

resource "azuread_application" "client" {
  for_each = local.clients

  display_name     = "${local.name}-${each.key}"
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = azuread_service_principal.api.app_role_ids[each.value]
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "client" {
  for_each = azuread_application.client

  client_id = each.value.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "client" {
  for_each = local.clients

  app_role_id         = azuread_service_principal.api.app_role_ids[each.value]
  principal_object_id = azuread_service_principal.client[each.key].object_id
  resource_object_id  = azuread_service_principal.api.object_id
}

# Demo shortcut: short-lived client secrets kept in local Terraform state.
# Production clients use certificates or federated credentials.
resource "azuread_application_password" "client" {
  for_each = azuread_application.client

  application_id = each.value.id
  display_name   = "hyperspectral-demo"
  end_date       = timeadd(timestamp(), "720h")

  lifecycle {
    # Fix the expiry at creation instead of recomputing it on every plan.
    ignore_changes = [end_date]
  }
}
