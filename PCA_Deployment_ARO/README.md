# PCA Deployment — Azure Red Hat OpenShift (ARO)

This folder contains Terraform and GitOps (ArgoCD) artifacts to deploy the
**Private AI Code Assistant** on **Azure Red Hat OpenShift (ARO)** with an
NVIDIA A100 GPU node for LLM inference.

---

## Prerequisites

### Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| `terraform` | >= 1.4.6 | Infrastructure provisioning |
| `az` (Azure CLI) | >= 2.50 | Azure authentication and ARO credential retrieval |
| `oc` (OpenShift CLI) | >= 4.19 | Cluster interaction and GitOps bootstrap |
| `jq` | >= 1.6 | JSON processing in the GPU MachineSet script |

Install the Azure CLI: `brew install azure-cli` or see [aka.ms/installazurecliwindows](https://aka.ms/installazurecliwindows)

### Azure Permissions Required

Your Azure account (or the service principal running Terraform) needs:

- **Contributor** or **Owner** on the target subscription
- **User Access Administrator** (to create role assignments for the ARO service principal)
- **Azure Active Directory** — ability to create App Registrations and Service Principals

Register the ARO resource providers if not already registered:

```bash
az provider register --namespace Microsoft.RedHatOpenShift --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.Authorization --wait
```

### Red Hat Prerequisites

- A **Red Hat account** with an active OpenShift subscription
- **Pull secret** downloaded from [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret)
- **No HuggingFace token required — unsloth models are publicly accessible

---

## Cluster Specifications

| Component | Specification |
|-----------|--------------|
| Platform | Azure Red Hat OpenShift (ARO) |
| OpenShift version | 4.19.19 |
| Azure region | East US (`eastus`) |
| Master nodes | 3× `Standard_D8s_v5` |
| Worker nodes | 3× `Standard_D8s_v5` (auto-scaled 3–6) |
| GPU nodes | 1× `Standard_NC24ads_A100_v4` (NVIDIA A100 80 GB) |
| RHOAI version | 3.3 (`fast-3.x` channel) |
| AI Gateway | llm-d v0.4 (GA) |
| Model | unsloth/Qwen3.6-35B-A3B |

---

## Deployment Steps

### Step 1: Authenticate with Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### Step 2: Configure Terraform Variables

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in subscription_id, tenant_id, pull_secret, etc.
```

### Step 3: Deploy the ARO Cluster

```bash
terraform init
terraform plan -out=aro-plan.tfplan
terraform apply aro-plan.tfplan
```

This will:
1. Create the Resource Group, VNet, subnets, and NSG
2. Create an Azure AD Service Principal with required role assignments
3. Provision the ARO cluster (takes 35–45 minutes)
4. Log into the cluster using `oc`
5. Run `scripts/create-gpu-machineset.sh` to add the A100 GPU node (5–15 additional minutes)
6. Install the OpenShift GitOps operator
7. Deploy the ArgoCD App-of-Apps (if `gitops_repo_url` is set)

### Step 4: Retrieve Cluster Credentials

```bash
# Get the kubeadmin password
az aro list-credentials \
  --name aro-pca \
  --resource-group aro-pca-rg

# Get the API server URL
az aro show \
  --name aro-pca \
  --resource-group aro-pca-rg \
  --query apiserverProfile.url -o tsv

# Log in
oc login <API_URL> --username=kubeadmin --password=<PASSWORD>
```

### Step 5: Update GitOps Repo URL

Edit `argocd/00-app-of-apps.yaml` and replace `REPLACE_WITH_GITOPS_REPO_URL` with
the URL of your fork of the `Private_Code_Assistant` repository, then apply:

```bash
oc apply -f argocd/00-app-of-apps.yaml -n openshift-gitops
```

### Step 6: Set the HuggingFace Token

```bash
HF_TOKEN_B64=$(echo -n "hf_your_token_here" | base64)

oc patch secret hf-token -n ai-serving \
  --type='json' \
  -p='[{"op":"replace","path":"/data/token","value":"'"${HF_TOKEN_B64}"'"}]'
```

### Step 7: Validate the Deployment

```bash
./scripts/validate.sh
```

---

## GPU Node Details

The NVIDIA A100 MachineSet is created by `scripts/create-gpu-machineset.sh` after
cluster deployment. The script:

1. Discovers the cluster `infra_id` from the OpenShift infrastructure object
2. Clones an existing worker MachineSet as a template
3. Patches it for `Standard_NC24ads_A100_v4` with Gen2 image support and GPU labels/taints
4. Applies the new MachineSet and waits for the node to become ready

To manually trigger GPU node provisioning after cluster creation:

```bash
oc login <API_URL> --username=kubeadmin --password=<PASSWORD>
./scripts/create-gpu-machineset.sh Standard_NC24ads_A100_v4 aro-pca-rg eastus 1
```

Monitor the MachineSet:

```bash
oc get machineset -n openshift-machine-api
oc get machines -n openshift-machine-api
oc get nodes -l nvidia.com/gpu.present=true
```

---

## Key Differences from ROSA Deployment

| Aspect | ROSA (AWS) | ARO (Azure) |
|--------|-----------|-------------|
| GPU VM | `g6e.2xlarge` (L40S 48 GB) | `Standard_NC24ads_A100_v4` (A100 80 GB) |
| GPU provisioning | RHCS machine pool via Terraform | MachineSet script post-cluster |
| Storage class | `gp3-csi` | `managed-premium` |
| IDP | HTPasswd via RHCS Terraform resource | kubeadmin + manual HTPasswd |
| Inferentia nodes | Optional `inf2.24xlarge` pool | Not applicable (removed) |
| RHOAI channel | `stable-2.19` | `fast-3.x` (RHOAI 3.3) |
| llm-d / AI Gateway | Technology Preview | **GA at v0.4** |
| vLLM max-model-len | 32768 (L40S 48 GB) | **65536** (A100 80 GB) |

---

## Troubleshooting

**ARO cluster creation fails with "InsufficientQuota":**
Request an A100 quota increase in East US via Azure Portal → Quotas → Compute.
The `Standard_NC24ads_A100_v4` requires `Standard NCADSv4Family` quota.

**GPU node stuck in Provisioning:**
```bash
oc describe machine -n openshift-machine-api | grep -A 10 "Message"
```
Check for image SKU availability in your region and ensure Gen2 image support is available.

**NVIDIA driver pod CrashLoopBackOff:**
Ensure `useOpenShiftDriverToolkit: true` is set in the ClusterPolicy. This is required
for ARO as it uses the Red Hat Driver Toolkit for in-cluster driver compilation.

**Model pod not scheduling on GPU node:**
```bash
oc describe pod -n ai-serving -l serving.kserve.io/inferenceservice=qwen3-coder
```
Check nodeSelector matches `node.kubernetes.io/instance-type: Standard_NC24ads_A100_v4`
and that the GPU taint toleration is present.
