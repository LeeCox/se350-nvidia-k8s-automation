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

EXTRA_ARGS=()

# The operator ships its own containerized driver and enables it by default. That collides with a
# driver already installed on the host, so default to letting the host driver win when one is
# working. Set GPU_OPERATOR_DRIVER_ENABLED=true in config.env to force the containerized driver.
DRIVER_ENABLED="${GPU_OPERATOR_DRIVER_ENABLED:-auto}"
if [[ "$DRIVER_ENABLED" == "auto" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    DRIVER_ENABLED="false"
    log "Host NVIDIA driver detected ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)) - installing with driver.enabled=false"
  else
    DRIVER_ENABLED="true"
    log "No working host driver - letting the operator deploy its containerized driver"
  fi
fi
EXTRA_ARGS+=(--set "driver.enabled=$DRIVER_ENABLED")

# K3s keeps containerd's config and socket outside the default locations the toolkit expects, so
# point it at the K3s paths. Without this the toolkit writes a config nothing reads, and no
# 'nvidia' RuntimeClass ever appears.
if [[ -d /var/lib/rancher/k3s ]]; then
  K3S_CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
  K3S_CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
  log "K3s detected - pointing the toolkit at $K3S_CONTAINERD_CONFIG"
  EXTRA_ARGS+=(
    --set "toolkit.env[0].name=CONTAINERD_CONFIG"
    --set "toolkit.env[0].value=$K3S_CONTAINERD_CONFIG"
    --set "toolkit.env[1].name=CONTAINERD_SOCKET"
    --set "toolkit.env[1].value=$K3S_CONTAINERD_SOCKET"
    --set "toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS"
    --set "toolkit.env[2].value=nvidia"
    --set "toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT"
    --set-string "toolkit.env[3].value=true"
  )
fi

log "Installing/upgrading the GPU Operator in namespace $GPU_OPERATOR_NAMESPACE"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace "$GPU_OPERATOR_NAMESPACE" \
  --create-namespace \
  --wait --timeout 15m \
  "${VERSION_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"

log "GPU Operator pods:"
kubectl get pods -n "$GPU_OPERATOR_NAMESPACE"

log "Node GPU allocatable resource:"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
