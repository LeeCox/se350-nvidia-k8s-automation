#!/usr/bin/env bash
# Installs the NVIDIA GPU Operator so Kubernetes can discover and schedule against the GPU.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd helm
require_cmd kubectl

GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"

log "Adding the NVIDIA Helm repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
helm repo update

VERSION_ARGS=()
if [[ -n "${GPU_OPERATOR_VERSION:-}" ]]; then
  VERSION_ARGS=(--version "$GPU_OPERATOR_VERSION")
fi

log "Installing/upgrading the GPU Operator in namespace $GPU_OPERATOR_NAMESPACE"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace "$GPU_OPERATOR_NAMESPACE" \
  --create-namespace \
  --wait --timeout 15m \
  "${VERSION_ARGS[@]}"

log "GPU Operator pods:"
kubectl get pods -n "$GPU_OPERATOR_NAMESPACE"

log "Node GPU allocatable resource:"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
