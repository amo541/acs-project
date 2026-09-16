resource "azurerm_container_registry" "acr_acs_project" {
  name                = "acracsproject"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location
  sku                 = "Basic"
  admin_enabled       = false
}
