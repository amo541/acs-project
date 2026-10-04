resource "azurerm_virtual_network" "acs_project_vnet" {
  name                = "acs-project-vnet"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "acs_project_subnet" {
  name                 = "acs-project-subnet"
  resource_group_name  = azurerm_resource_group.rg_acs_project.name
  virtual_network_name = azurerm_virtual_network.acs_project_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "acs_project_public_ip" {
  name                = "acs-project-public-ip"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location
  allocation_method   = "Static"
  sku                 = "Standard"
}
