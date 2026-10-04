resource "azuread_application_registration" "github_actions" {
  display_name = "acs-project-github-actions"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application_registration.github_actions.client_id
}

resource "azuread_application_federated_identity_credential" "github_actions" {
  application_id = azuread_application_registration.github_actions.id
  display_name   = "github-actions-main"
  description    = "GitHub Actions OIDC trust for acs-project main branch"
  audiences       = ["api://AzureADTokenExchange"]
  issuer          = "https://token.actions.githubusercontent.com"
  subject         = "repo:amo541@182442816/acs-project@1361986982:ref:refs/heads/main"
}

resource "azurerm_role_assignment" "github_actions_acr_push" {
  scope                = azurerm_container_registry.acr_acs_project.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions.object_id
}
