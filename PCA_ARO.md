# Private AI Code Assistant — Azure Red Hat OpenShift (ARO) Deployment

> **Status:** Deployment artifacts complete. Performance benchmarks to be updated after test environment validation (Phase 2).

---

## Overview

This document describes the architecture and deployment of the **Private AI Code Assistant (PCA)**
on **Azure Red Hat OpenShift (ARO)**. The ARO deployment is functionally equivalent to the
ROSA-based deployment, updated for Azure infrastructure, the NVIDIA A100 GPU, and
**Red Hat OpenShift AI 3.3** with the **llm-d AI Gateway now GA**.

The PCA provides enterprise development teams with a self-hosted, air-gappable AI coding
assistant powered by **Qwen3.6-35B-A3B** — with no data leaving the customer's Azure environment.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Azure Red Hat OpenShift (ARO)                       │
│                        Central US — OCP 4.19                            │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      Developer Tier                              │   │
│  │  OpenShift Dev Spaces  ──  VS Code in Browser                   │   │
│  │  Roo Code · Continue · Cline   (AI coding extensions)           │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │ HTTPS (cluster-internal)                    │
│  ┌────────────────────────▼────────────────────────────────────────┐   │
│  │                   AI Gateway Tier                                │   │
│  │  llm-d Gateway (GA v0.4)  ──  EPP Endpoint Picker               │   │
│  │  OpenAI-compatible API  ·  Prefix cache routing                  │   │
│  └────────────────────────┬────────────────────────────────────────┘   │
│                           │                                             │
│  ┌────────────────────────▼────────────────────────────────────────┐   │
│  │                 AI Inference Tier                                │   │
│  │  vLLM + KServe (RHOAI 3.3.2)                                    │   │
│  │  Qwen3.6-35B-A3B-FP8                               │   │
│  │  NVIDIA A100 80 GB  ·  BF16 compute  ·  FP8 KV cache            │   │
│  │  Standard_NC24ads_A100_v4  ($3.67/hr)                           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌────────────────────────────┐  ┌──────────────────────────────────┐  │
│  │     Platform Operators     │  │       Azure Infrastructure       │  │
│  │  RHOAI 3.3.2 (stable-3.x) │  │  Resource Group · VNet           │  │
│  │  OpenShift GitOps          │  │  Azure AD Service Principal      │  │
│  │  NVIDIA GPU Operator       │  │  managed-csi storage         │  │
│  │  Service Mesh · Serverless │  │  Central US region               │  │
│  └────────────────────────────┘  └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Why NVIDIA A100 on Azure?

Azure does not offer NVIDIA L40S virtual machines (the GPU used on AWS `g6e.2xlarge`).
The closest available GPU for single-node LLM inference on Azure is the A100:

| GPU | VRAM | FP8 | Azure VM | $/hr (Central US) |
|-----|------|-----|----------|---------------|
| NVIDIA L40S (AWS) | 48 GB GDDR6 | Yes | `g6e.2xlarge` | $2.07 |
| **NVIDIA A100 (Azure)** | **80 GB HBM2** | **Yes** | `Standard_NC24ads_A100_v4` | **$3.67** |
| NVIDIA A10 (Azure) | 24 GB max | No | `NV36ads_A10_v5` | $3.20 |
| NVIDIA H100 NVL (Azure) | 94 GB | Yes | `NC40ads_H100_v5` | $6.98 |

The A100 is the right choice because:
- **Single-GPU fit:** 80 GB fits Qwen3.6-35B-A3B at FP8 (~30 GB weights) with a 65,536-token
  context window and KV cache — comfortably larger than the 32,768-token window on L40S
- **FP8 support:** Native FP8 on Ampere for inference acceleration
- **No tensor parallelism needed:** Single-GPU inference avoids multi-GPU coordination overhead
- **A10 ruled out:** Maximum 24 GB per Azure A10 VM — too small for Qwen3.6-35B-A3B
- **H100 ruled out:** ~2× the cost for incremental throughput gains on a 30B model

---

## Infrastructure

| Resource | Type | Count |
|----------|------|-------|
| ARO Cluster | OCP 4.19 | 1 |
| Master nodes | `Standard_D8s_v5` | 3 |
| Worker nodes | `Standard_D8s_v5` | 3 (auto-scaled 3–6) |
| GPU nodes | `Standard_NC24ads_A100_v4` | 1 |
| Virtual Network | Azure VNet | 1 |
| Subnets | Master + Worker | 2 |
| Storage | managed-csi PVC | 100 Gi |

**Estimated monthly cost (Central US, pay-as-you-go):**
- ARO cluster fee: ~$0.18/hr (Microsoft managed control plane)
- 3× `Standard_D8s_v5` workers: ~$1.15/hr
- 1× `Standard_NC24ads_A100_v4` GPU node: $3.67/hr
- Storage, networking: ~$50–100/month
- **Total (approximate): ~$4,000–4,500/month** for a 24×7 deployment

Cost optimisation options: Azure Reserved Instances (1-year) provide ~40% savings on compute.

---

## Deployment

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/manu-joy/Private_Code_Assistant.git
cd Private_Code_Assistant

# 2. Install prerequisites
# - terraform >= 1.4.6
# - azure-cli >= 2.50
# - oc >= 4.19

# 3. Authenticate
az login
az account set --subscription "<your-subscription-id>"

# 4. Register ARO providers (first time only)
az provider register --namespace Microsoft.RedHatOpenShift --wait
az provider register --namespace Microsoft.Compute --wait

# 5. Configure variables
cd PCA_Deployment_ARO/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in subscription_id, tenant_id, pull_secret

# 6. Deploy
terraform init
terraform apply

# 7. Validate (~45 minutes after terraform apply)
oc login <API_URL> --username=kubeadmin --password=<PASSWORD>
../scripts/validate.sh
```

For full deployment instructions, see [PCA_Deployment_ARO/README.md](PCA_Deployment_ARO/README.md).

---

## Model Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Model | `Qwen/Qwen3.6-35B-A3B-FP8` | State-of-the-art code reasoning, FP8 quantized |
| GPU | NVIDIA A100 80 GB | Single-GPU fit with headroom |
| dtype | `bf16` | A100 native compute dtype (better than fp16 for training stability) |
| max-model-len | 65,536 | Full 65K context window enabled by A100's 80 GB HBM2 |
| KV cache dtype | `fp8` | Maximises KV cache capacity on A100 |
| GPU memory utilization | 90% | Leaves 8 GB headroom for activation memory |
| Tool call parser | `qwen3_coder` | Required for Roo Code structured tool calls |
| Reasoning parser | `qwen3` | Strips `<think>` tokens from responses |

---

## GitOps Structure

```
PCA_Deployment_ARO/
├── terraform/          # Azure infrastructure (ARO cluster, VNet, AD SP)
├── argocd/
│   ├── 00-app-of-apps.yaml       # Root ArgoCD application
│   ├── 01-operators/             # RHOAI 3.3.2, NVIDIA GPU Operator, DevSpaces
│   ├── 02-platform-config/       # DataScienceCluster, CheCluster, namespaces, RBAC
│   ├── 03-ai-serving/            # LLMInferenceService, llm-d Gateway, PVCs
│   └── 04-devspaces/             # DevWorkspaces, VS Code extension config
└── scripts/
    ├── create-gpu-machineset.sh  # Post-cluster A100 node provisioning
    └── validate.sh               # Post-deployment validation
```

---

## Performance Benchmarks

> **Phase 2 — Pending test environment validation.**
>
> Performance results will be published here after running `guidellm` benchmark sweeps
> on the ARO cluster. The following table is a placeholder.

### guidellm Sweep Results (To Be Updated)

**Test Configuration:**
- Model: `Qwen/Qwen3.6-35B-A3B-FP8`
- GPU: `Standard_NC24ads_A100_v4` (NVIDIA A100 80 GB)
- Concurrency: 1, 2, 4, 8, 16 simultaneous requests
- Prompt lengths: 256, 512, 1024, 2048 tokens
- Output lengths: 128, 256, 512 tokens

```bash
# Command used to generate benchmarks (to be run after cluster deployment):
guidellm benchmark \
  --target https://llm-d-gateway-data-science-gateway-class.ai-serving.svc.cluster.local/v1 \
  --model Qwen/Qwen3.6-35B-A3B-FP8 \
  --max-requests 200 \
  --rate-type sweep \
  --output-path ./benchmark-results/aro-a100-sweep.json
```

| Concurrency | Prompt Tokens | Output Tokens | Throughput (tok/s) | TTFT (ms) | ITL (ms) |
|-------------|---------------|---------------|---------------------|-----------|----------|
| 1 | 256 | 128 | _TBD_ | _TBD_ | _TBD_ |
| 1 | 512 | 256 | _TBD_ | _TBD_ | _TBD_ |
| 2 | 512 | 256 | _TBD_ | _TBD_ | _TBD_ |
| 4 | 512 | 256 | _TBD_ | _TBD_ | _TBD_ |
| 8 | 1024 | 512 | _TBD_ | _TBD_ | _TBD_ |
| 16 | 1024 | 512 | _TBD_ | _TBD_ | _TBD_ |

_TTFT = Time to First Token · ITL = Inter-Token Latency_

**Expected performance baseline (pre-test estimate based on A100 published data):**
- Single-user TTFT: < 500 ms for 512-token prompts
- Throughput at concurrency 4: ~800–1,200 tokens/sec (BF16 compute, FP8 KV cache)

---

## Roadmap

- [ ] Run `guidellm` sweep and populate benchmark table above
- [ ] Validate HTPasswd IDP configuration for DevSpaces user onboarding
- [ ] Test Roo Code, Continue, and Cline end-to-end within ARO Dev Spaces
- [ ] Add architecture diagrams: Azure infrastructure view, AI serving traffic flow, DevSpaces user journey, and Red Hat component stack view
- [ ] Document any ARO-specific networking or security group adjustments found during testing
- [ ] Evaluate Azure Reserved Instance pricing for 1-year commitment
