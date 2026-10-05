data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

# The operator becomes the PostgreSQL Microsoft Entra administrator so it can seed data.
data "azuread_user" "operator" {
  object_id = data.azuread_client_config.current.object_id
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name      = "${var.name_prefix}-${random_id.suffix.hex}"
  tenant_id = data.azurerm_client_config.current.tenant_id
  tags = {
    workload     = "hyperspectral-dab-demo"
    environment  = "demo"
    "managed-by" = "terraform"
  }

  database_name = "imagery"
  dab_image     = "mcr.microsoft.com/azure-databases/data-api-builder:2.0.12@sha256:85db5c7f1af9d0bc93af824a0602285880a07dba210854bc68394e08d9d338ac"
  dab_config    = file("${path.module}/../dab/dab-config.json")

  # No password: DAB requests an Entra token for its managed identity.
  database_connection_string = join(";", [
    "Host=${azurerm_postgresql_flexible_server.imagery.fqdn}",
    "Port=5432",
    "Database=${local.database_name}",
    "Username=${azurerm_user_assigned_identity.dab.name}",
    "SSL Mode=VerifyFull",
    "Root Certificate=/etc/ssl/certs/ca-certificates.crt",
    "Maximum Pool Size=5",
    "Timeout=5",
    "Command Timeout=5",
  ])
}

resource "azurerm_resource_group" "demo" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "demo" {
  name                = "log-${local.name}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "dab" {
  name                = "id-dab-${local.name}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  tags                = local.tags
}

# PostgreSQL --------------------------------------------------------------------

resource "azurerm_postgresql_flexible_server" "imagery" {
  name                          = "psql-${local.name}"
  resource_group_name           = azurerm_resource_group.demo.name
  location                      = azurerm_resource_group.demo.location
  version                       = "17"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  storage_tier                  = "P4"
  backup_retention_days         = 7
  public_network_access_enabled = true
  tags                          = local.tags

  # Microsoft Entra only: no password exists for any database login.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = local.tenant_id
  }

  lifecycle {
    # Azure picks a zone when none is requested; keep it on later applies.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "operator" {
  server_name         = azurerm_postgresql_flexible_server.imagery.name
  resource_group_name = azurerm_resource_group.demo.name
  tenant_id           = local.tenant_id
  object_id           = data.azuread_client_config.current.object_id
  principal_name      = data.azuread_user.operator.user_principal_name
  principal_type      = "User"
}

resource "azurerm_postgresql_flexible_server_database" "imagery" {
  name      = local.database_name
  server_id = azurerm_postgresql_flexible_server.imagery.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Demo shortcut: Container Apps reaches PostgreSQL over the public endpoint.
# Production uses private access in a virtual network instead.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.imagery.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "operator" {
  name             = "allow-operator"
  server_id        = azurerm_postgresql_flexible_server.imagery.id
  start_ip_address = var.operator_ip
  end_ip_address   = var.operator_ip
}

# Data API builder on Container Apps ---------------------------------------------

resource "azurerm_container_app_environment" "demo" {
  name                       = "cae-${local.name}"
  resource_group_name        = azurerm_resource_group.demo.name
  location                   = azurerm_resource_group.demo.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.demo.id
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "dab" {
  name                         = "ca-dab-${local.name}"
  resource_group_name          = azurerm_resource_group.demo.name
  container_app_environment_id = azurerm_container_app_environment.demo.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dab.id]
  }

  # The configuration ships as a secret file on Microsoft's pinned image; no custom image.
  secret {
    name  = "dab-config"
    value = local.dab_config
  }

  ingress {
    # Public so APIM Basic v2 can reach it; DAB still validates every token itself.
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 5000
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "config"
      storage_type = "Secret"
    }

    container {
      name   = "dab"
      image  = local.dab_image
      cpu    = 0.5
      memory = "1Gi"

      volume_mounts {
        name = "config"
        path = "/App/config"
      }

      env {
        name  = "ConfigFileName"
        value = "/App/config/dab-config"
      }
      env {
        # Secret updates alone don't roll a revision; a changed hash does.
        name  = "DAB_CONFIG_SHA256"
        value = sha256(local.dab_config)
      }
      env {
        name  = "DATABASE_CONNECTION_STRING"
        value = local.database_connection_string
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.dab.client_id
      }
      env {
        name  = "DAB_JWT_ISSUER"
        value = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"
      }
      env {
        name  = "API_AUDIENCE"
        value = azuread_application.api.client_id
      }
      env {
        name  = "ASPNETCORE_URLS"
        value = "http://+:5000"
      }

      startup_probe {
        transport               = "TCP"
        port                    = 5000
        interval_seconds        = 5
        failure_count_threshold = 60
      }

      liveness_probe {
        transport = "TCP"
        port      = 5000
      }
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_database.imagery,
    azurerm_postgresql_flexible_server_firewall_rule.azure_services,
  ]
}
