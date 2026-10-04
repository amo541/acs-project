resource "azurerm_log_analytics_workspace" "acs_project_log_analytics" {
  name                = "acs-log-analytics"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "acs_project_env" {
  name                       = "acs-project-env"
  resource_group_name        = azurerm_resource_group.rg_acs_project.name
  location                   = azurerm_resource_group.rg_acs_project.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.acs_project_log_analytics.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_user_assigned_identity" "acr_pull_identity" {
  name                = "acs-acr-pull-identity"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr_acs_project.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.acr_pull_identity.principal_id
}

resource "azurerm_container_app" "acs_project_app" {
  name                         = "acs-project-app"
  resource_group_name          = azurerm_resource_group.rg_acs_project.name
  container_app_environment_id = azurerm_container_app_environment.acs_project_env.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr_pull_identity.id]
  }

  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }


  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "coderco-task-app"
      image  = "${azurerm_container_registry.acr_acs_project.login_server}/coderco-task-app:v1"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  registry {
    server   = azurerm_container_registry.acr_acs_project.login_server
    identity = azurerm_user_assigned_identity.acr_pull_identity.id
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
