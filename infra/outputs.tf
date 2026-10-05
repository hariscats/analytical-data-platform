output "apim_gateway_url" {
  description = "Public API base: <url>/api/scenes and <url>/api/spectra."
  value       = azurerm_api_management.demo.gateway_url
}

output "dab_url" {
  description = "Direct Container Apps URL, used only to show that bypassing APIM doesn't bypass DAB."
  value       = "https://${azurerm_container_app.dab.ingress[0].fqdn}"
}

output "resource_group_name" {
  value = azurerm_resource_group.demo.name
}

output "container_app_name" {
  value = azurerm_container_app.dab.name
}

output "container_app_id" {
  value = azurerm_container_app.dab.id
}

output "postgres_host" {
  value = azurerm_postgresql_flexible_server.imagery.fqdn
}

output "postgres_admin" {
  description = "Microsoft Entra administrator used to seed the database."
  value       = data.azuread_user.operator.user_principal_name
}

output "database_name" {
  value = local.database_name
}

output "dab_principal_name" {
  description = "PostgreSQL role name for DAB's managed identity."
  value       = azurerm_user_assigned_identity.dab.name
}

output "dab_principal_object_id" {
  value = azurerm_user_assigned_identity.dab.principal_id
}

output "tenant_id" {
  value = local.tenant_id
}

output "api_scope" {
  description = "Client-credentials scope for the imagery API."
  value       = "${local.identifier_uri}/.default"
}

output "clients" {
  description = "Demo client credentials and their single app role."
  sensitive   = true
  value = {
    for name, role in local.clients : name => {
      client_id     = azuread_application.client[name].client_id
      client_secret = azuread_application_password.client[name].value
      role          = role
    }
  }
}
