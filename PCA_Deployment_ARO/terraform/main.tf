locals {
  cluster_name = var.cluster_name
  domain       = var.domain != "" ? var.domain : var.cluster_name
  tags = {
    Project     = "private-code-assistant"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

# ════════════════════════════════════════════════
# Resource Group
# ════════════════════════════════════════════════
resource "azurerm_resource_group" "aro" {
  name     = "${local.cluster_name}-rg"
  location = var.location
  tags     = local.tags
}

# ════════════════════════════════════════════════
# Virtual Network
# ════════════════════════════════════════════════
resource "azurerm_virtual_network" "aro" {
  name                = "${local.cluster_name}-vnet"
  location            = azurerm_resource_group.aro.location
  resource_group_name = azurerm_resource_group.aro.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

# Master (control plane) subnet — private endpoint policies must be disabled for ARO
resource "azurerm_subnet" "master" {
  name                 = "${local.cluster_name}-master-subnet"
  resource_group_name  = azurerm_resource_group.aro.name
  virtual_network_name = azurerm_virtual_network.aro.name
  address_prefixes     = [var.master_subnet_cidr]

  private_link_service_network_policies_enabled = false
  private_endpoint_network_policies             = "Disabled"

  service_endpoints = ["Microsoft.ContainerRegistry"]
}

# Worker (compute) subnet
resource "azurerm_subnet" "worker" {
  name                 = "${local.cluster_name}-worker-subnet"
  resource_group_name  = azurerm_resource_group.aro.name
  virtual_network_name = azurerm_virtual_network.aro.name
  address_prefixes     = [var.worker_subnet_cidr]

  service_endpoints = ["Microsoft.ContainerRegistry"]
}

# ════════════════════════════════════════════════
# Network Security Group (ARO minimum rules)
# ════════════════════════════════════════════════
resource "azurerm_network_security_group" "aro" {
  name                = "${local.cluster_name}-nsg"
  location            = azurerm_resource_group.aro.location
  resource_group_name = azurerm_resource_group.aro.name
  tags                = local.tags

  security_rule {
    name                       = "AllowInternalVnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowARO"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["6443", "443", "80"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "master" {
  subnet_id                 = azurerm_subnet.master.id
  network_security_group_id = azurerm_network_security_group.aro.id
}

resource "azurerm_subnet_network_security_group_association" "worker" {
  subnet_id                 = azurerm_subnet.worker.id
  network_security_group_id = azurerm_network_security_group.aro.id
}

# ════════════════════════════════════════════════
# Azure AD Service Principal for ARO
# ════════════════════════════════════════════════
resource "azuread_application" "aro" {
  display_name = var.service_principal_name
}

resource "azuread_service_principal" "aro" {
  client_id = azuread_application.aro.client_id
}

resource "azuread_service_principal_password" "aro" {
  service_principal_id = azuread_service_principal.aro.id
  end_date             = timeadd(timestamp(), "8760h") # 1 year
}

# Network Contributor on the VNet (ARO needs to manage network resources)
resource "azurerm_role_assignment" "aro_vnet_contributor" {
  scope                = azurerm_virtual_network.aro.id
  role_definition_name = "Network Contributor"
  principal_id         = azuread_service_principal.aro.object_id
}

# Contributor on the resource group (ARO creates internal resource group + managed resources)
resource "azurerm_role_assignment" "aro_rg_contributor" {
  scope                = azurerm_resource_group.aro.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.aro.object_id
}

# ════════════════════════════════════════════════
# ARO Cluster
# ════════════════════════════════════════════════
resource "azurerm_redhat_openshift_cluster" "aro" {
  name                = local.cluster_name
  location            = azurerm_resource_group.aro.location
  resource_group_name = azurerm_resource_group.aro.name
  tags                = local.tags

  cluster_profile {
    domain      = local.domain
    version     = var.aro_version
    pull_secret = var.pull_secret
  }

  network_profile {
    pod_cidr     = var.pod_cidr
    service_cidr = var.service_cidr
  }

  main_profile {
    vm_size   = var.master_vm_size
    subnet_id = azurerm_subnet.master.id
  }

  worker_profile {
    vm_size      = var.worker_vm_size
    subnet_id    = azurerm_subnet.worker.id
    disk_size_gb = var.worker_disk_size_gb
    node_count   = var.worker_replicas
  }

  api_server_profile {
    visibility = "Public"
  }

  ingress_profile {
    visibility = "Public"
  }

  service_principal {
    client_id     = azuread_application.aro.client_id
    client_secret = azuread_service_principal_password.aro.value
  }

  depends_on = [
    azurerm_role_assignment.aro_vnet_contributor,
    azurerm_role_assignment.aro_rg_contributor,
  ]
}

# ════════════════════════════════════════════════
# Post-Cluster: Login and Grant cluster-admin
# ════════════════════════════════════════════════
resource "null_resource" "oc_login" {
  triggers = {
    cluster_id = azurerm_redhat_openshift_cluster.aro.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Retrieving ARO credentials..."

      API_URL="${azurerm_redhat_openshift_cluster.aro.api_server_profile[0].url}"
      KUBEADMIN_PASS=$(az aro list-credentials \
        --name ${local.cluster_name} \
        --resource-group ${azurerm_resource_group.aro.name} \
        --query kubeadminPassword -o tsv)

      echo "Logging into ARO cluster..."
      oc login "$API_URL" \
        --username=kubeadmin \
        --password="$KUBEADMIN_PASS" \
        --insecure-skip-tls-verify=true

      echo "Cluster login successful."
    EOT
  }

  depends_on = [azurerm_redhat_openshift_cluster.aro]
}

# ════════════════════════════════════════════════
# GPU MachineSet (A100 — post-cluster provisioning)
# ARO Terraform only supports one worker profile at cluster creation.
# GPU nodes are added via MachineSet after the cluster is ready.
# ════════════════════════════════════════════════
resource "null_resource" "gpu_machineset" {
  triggers = {
    cluster_id   = azurerm_redhat_openshift_cluster.aro.id
    gpu_vm_size  = var.gpu_vm_size
    gpu_replicas = var.gpu_node_replicas
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Creating GPU MachineSet for ${var.gpu_vm_size}..."
      chmod +x ${path.module}/../scripts/create-gpu-machineset.sh
      ${path.module}/../scripts/create-gpu-machineset.sh \
        "${var.gpu_vm_size}" \
        "${azurerm_resource_group.aro.name}" \
        "${var.location}" \
        "${var.gpu_node_replicas}"
      echo "GPU MachineSet created."
    EOT
  }

  depends_on = [null_resource.oc_login]
}
