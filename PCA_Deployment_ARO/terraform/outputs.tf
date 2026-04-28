output "cluster_id" {
  description = "ARO cluster resource ID"
  value       = azurerm_redhat_openshift_cluster.aro.id
}

output "cluster_api_url" {
  description = "OpenShift API server URL"
  value       = azurerm_redhat_openshift_cluster.aro.api_server_profile[0].url
}

output "cluster_console_url" {
  description = "OpenShift web console URL"
  value       = azurerm_redhat_openshift_cluster.aro.console_url
}

output "resource_group_name" {
  description = "Azure resource group containing the ARO cluster"
  value       = azurerm_resource_group.aro.name
}

output "vnet_id" {
  description = "Azure Virtual Network ID"
  value       = azurerm_virtual_network.aro.id
}

output "service_principal_client_id" {
  description = "Client ID of the service principal created for ARO"
  value       = azuread_application.aro.client_id
}

output "get_credentials_command" {
  description = "Command to retrieve ARO kubeadmin credentials via Azure CLI"
  value       = "az aro list-credentials --name ${azurerm_redhat_openshift_cluster.aro.name} --resource-group ${azurerm_resource_group.aro.name}"
}
