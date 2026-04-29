#!/usr/bin/env bash
# create-gpu-machineset.sh
# Creates an ARO MachineSet for NVIDIA A100 GPU nodes (Standard_NC24ads_A100_v4).
# ARO Terraform provider supports only one worker profile at cluster creation time;
# GPU nodes are added post-deployment by cloning an existing worker MachineSet and
# patching it for the GPU VM size with the required Gen2 image SKU.
#
# Usage:
#   ./create-gpu-machineset.sh [GPU_VM_SIZE] [RESOURCE_GROUP] [LOCATION] [REPLICAS]
#
# All arguments are optional — defaults are read from the active oc context.
set -euo pipefail

GPU_VM_SIZE="${1:-Standard_NC24ads_A100_v4}"
RESOURCE_GROUP="${2:-}"
LOCATION="${3:-centralus}"
REPLICAS="${4:-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v oc  &>/dev/null || error "'oc' CLI not found. Install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
command -v jq  &>/dev/null || error "'jq' not found. Install with: brew install jq  or  dnf install jq"

# Verify cluster access
oc whoami &>/dev/null || error "Not logged in to OpenShift. Run 'oc login' first."

info "Starting GPU MachineSet creation for ${GPU_VM_SIZE}..."

# ── Gather cluster metadata ───────────────────────────────────────────────────
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
info "Infrastructure ID: ${INFRA_ID}"

CLUSTER_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' 2>/dev/null || echo "${LOCATION}")
info "Cluster region: ${LOCATION}"

# Get the resource group from the cluster if not provided
if [[ -z "${RESOURCE_GROUP}" ]]; then
  RESOURCE_GROUP=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
  info "Detected resource group: ${RESOURCE_GROUP}"
fi

# ── Clone an existing worker MachineSet as template ───────────────────────────
TEMPLATE_MS=$(oc get machineset -n openshift-machine-api -o name | grep "worker" | head -1)
[[ -z "${TEMPLATE_MS}" ]] && error "No worker MachineSet found to clone. Ensure the cluster has at least one worker MachineSet."

info "Using template MachineSet: ${TEMPLATE_MS}"

GPU_MS_NAME="${INFRA_ID}-gpu-a100"
TEMPLATE_JSON=$(oc get "${TEMPLATE_MS}" -n openshift-machine-api -o json)

# ── Build GPU MachineSet manifest ─────────────────────────────────────────────
GPU_MS_JSON=$(echo "${TEMPLATE_JSON}" | jq --arg name "${GPU_MS_NAME}" \
  --arg vm_size "${GPU_VM_SIZE}" \
  --argjson replicas "${REPLICAS}" \
  '
  # Strip runtime-managed fields
  del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
      .status, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])
  # Rename
  | .metadata.name = $name
  | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
  | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
  # Set replicas
  | .spec.replicas = $replicas
  # Set VM size
  | .spec.template.spec.providerSpec.value.vmSize = $vm_size
  # A100 requires Hyper-V Gen2 — override image SKU to the Gen2 variant
  # (default workers use aro_4XX which is Gen1; 4XX-v2 is the Gen2 equivalent)
  # Derive the Gen2 SKU from the existing Gen1 SKU (e.g. aro_419 → 419-v2)
  | .spec.template.spec.providerSpec.value.image.sku = (
      .spec.template.spec.providerSpec.value.image.sku
      | sub("^aro_"; "")
      | . + "-v2"
    )
  # GPU-specific labels
  | .spec.template.spec.metadata.labels["nvidia.com/gpu.present"] = "true"
  | .spec.template.spec.metadata.labels["node-role.kubernetes.io/gpu"] = ""
  | .spec.template.spec.metadata.labels["node.kubernetes.io/instance-type"] = $vm_size
  # GPU taint — prevents non-GPU workloads from landing on these nodes
  | .spec.template.spec.taints = [{
      "key": "nvidia.com/gpu",
      "value": "present",
      "effect": "NoSchedule"
    }]
  ')

# ── Apply the GPU MachineSet ──────────────────────────────────────────────────
if oc get machineset "${GPU_MS_NAME}" -n openshift-machine-api &>/dev/null; then
  warn "MachineSet ${GPU_MS_NAME} already exists. Applying update..."
  echo "${GPU_MS_JSON}" | oc apply -f -
else
  info "Creating GPU MachineSet ${GPU_MS_NAME}..."
  echo "${GPU_MS_JSON}" | oc apply -f -
fi

# ── Wait for machines to be provisioned ───────────────────────────────────────
info "Waiting for GPU MachineSet to scale up (this takes 5-15 minutes for A100 VMs)..."
for i in $(seq 1 90); do
  READY=$(oc get machineset "${GPU_MS_NAME}" -n openshift-machine-api \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(oc get machineset "${GPU_MS_NAME}" -n openshift-machine-api \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${REPLICAS}")
  if [[ "${READY}" == "${DESIRED}" && "${READY}" != "0" ]]; then
    info "GPU MachineSet is ready: ${READY}/${DESIRED} nodes."
    break
  fi
  echo "  Waiting for GPU nodes... ready=${READY}/${DESIRED} (attempt ${i}/90)"
  sleep 20
done

FINAL_READY=$(oc get machineset "${GPU_MS_NAME}" -n openshift-machine-api \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${FINAL_READY}" != "${REPLICAS}" ]]; then
  warn "GPU MachineSet may still be provisioning. Check with:"
  warn "  oc get machineset ${GPU_MS_NAME} -n openshift-machine-api"
  warn "  oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${GPU_MS_NAME}"
fi

info "GPU MachineSet ${GPU_MS_NAME} created successfully."
info "Verify GPU nodes with: oc get nodes -l nvidia.com/gpu.present=true"
