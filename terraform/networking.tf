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

resource "azurerm_application_gateway" "acs_project_appgw" {
  name                = "acs-project-appgw"
  resource_group_name = azurerm_resource_group.rg_acs_project.name
  location            = azurerm_resource_group.rg_acs_project.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.acs_project_subnet.id
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.acs_project_public_ip.id
  }

  backend_address_pool {
    name  = "backend-pool"
    fqdns = [azurerm_container_app.acs_project_app.ingress[0].fqdn]
  }

  probe {
    name                                       = "health-probe"
    protocol                                   = "Https"
    path                                       = "/"
    interval                                   = 30
    timeout                                    = 30
    unhealthy_threshold                        = 3
    pick_host_name_from_backend_http_settings  = true
  }

  backend_http_settings {
    name                                 = "backend-http-settings"
    cookie_based_affinity                = "Disabled"
    port                                 = 443
    protocol                             = "Https"
    request_timeout                      = 20
    pick_host_name_from_backend_address  = true
    probe_name                           = "health-probe"
  }

  ssl_certificate {
    name     = "appgw-ssl-cert"
    data     = filebase64("certs/appgw.pfx")
    password = var.appgw_cert_password
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "port-443"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw-ssl-cert"
    host_name                      = "tm.amatechvault.com"
  }

  request_routing_rule {
    name                        = "routing-rule"
    rule_type                   = "Basic"
    http_listener_name          = "https-listener"
    backend_address_pool_name   = "backend-pool"
    backend_http_settings_name  = "backend-http-settings"
    priority                    = 100
  }
}
