resource "azurerm_api_management" "demo" {
  name                = "apim-${local.name}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  publisher_name      = "Hyperspectral DAB demo"
  publisher_email     = var.publisher_email
  sku_name            = "BasicV2_1"
  tags                = local.tags
}

# The public path prefix matches DAB's REST path, so DAB's relative nextLink
# resolves unchanged on the APIM host.
resource "azurerm_api_management_api" "imagery" {
  name                  = "imagery"
  resource_group_name   = azurerm_resource_group.demo.name
  api_management_name   = azurerm_api_management.demo.name
  revision              = "1"
  display_name          = "Hyperspectral imagery"
  path                  = "api"
  protocols             = ["https"]
  service_url           = "https://${azurerm_container_app.dab.ingress[0].fqdn}/api"
  subscription_required = false
}

resource "azurerm_api_management_api_policy" "imagery" {
  api_name            = azurerm_api_management_api.imagery.name
  api_management_name = azurerm_api_management.demo.name
  resource_group_name = azurerm_resource_group.demo.name
  xml_content = templatefile("${path.module}/policies/api.xml.tftpl", {
    tenant_id = local.tenant_id
    audience  = azuread_application.api.client_id
    roles     = keys(local.app_roles)
  })
}

# Only these two GET operations exist; any other method or path is rejected by APIM.
resource "azurerm_api_management_api_operation" "scenes" {
  operation_id        = "list-scenes"
  api_name            = azurerm_api_management_api.imagery.name
  api_management_name = azurerm_api_management.demo.name
  resource_group_name = azurerm_resource_group.demo.name
  display_name        = "List scenes"
  description         = "Grain: one row per scene acquisition."
  method              = "GET"
  url_template        = "/scenes"
}

resource "azurerm_api_management_api_operation" "spectra" {
  operation_id        = "list-spectra"
  api_name            = azurerm_api_management_api.imagery.name
  api_management_name = azurerm_api_management.demo.name
  resource_group_name = azurerm_resource_group.demo.name
  display_name        = "List spectral samples"
  description         = "Grain: one reflectance sample per scene, pixel, and band. Requires a scene_id filter."
  method              = "GET"
  url_template        = "/spectra"
}

resource "azurerm_api_management_api_operation_policy" "spectra" {
  api_name            = azurerm_api_management_api.imagery.name
  api_management_name = azurerm_api_management.demo.name
  resource_group_name = azurerm_resource_group.demo.name
  operation_id        = azurerm_api_management_api_operation.spectra.operation_id
  xml_content         = file("${path.module}/policies/spectra.xml")
}
