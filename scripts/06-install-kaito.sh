#!/usr/bin/env bash
# Installs the KAITO workspace controller in "bring your own GPU node" mode (no cloud
# auto-provisioner) and labels the current node so KAITO Workspaces can select it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd helm
require_cmd kubectl

CLUSTER_NAME="${CLUSTER_NAME:-se350-lab}"
KAITO_NAMESPACE="${KAITO_NAMESPACE:-kaito-workspace}"
KAITO_NODE_LABEL_KEY="${KAITO_NODE_LABEL_KEY:-apps}"
KAITO_NODE_LABEL_VALUE="${KAITO_NODE_LABEL_VALUE:-llm-inference}"

log "Adding the KAITO Helm repo"
helm repo add kaito https://kaito-project.github.io/kaito/charts/kaito --force-update
helm repo update

# BYO nodes require Node Auto Provisioning disabled - otherwise KAITO tries to call a
# cloud provisioner (Karpenter/gpu-provisioner) that does not exist on this on-prem host.
log "Installing KAITO workspace controller (BYO GPU node mode) in namespace $KAITO_NAMESPACE"
helm upgrade --install kaito-workspace kaito/workspace \
  --namespace "$KAITO_NAMESPACE" \
  --create-namespace \
  --set clusterName="$CLUSTER_NAME" \
  --set featureGates.disableNodeAutoProvisioning=true \
  --wait --take-ownership

log "Verifying the controller is running"
kubectl get pods -n "$KAITO_NAMESPACE"

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
log "Labeling node $NODE_NAME with ${KAITO_NODE_LABEL_KEY}=${KAITO_NODE_LABEL_VALUE} so Workspaces can select it"
kubectl label node "$NODE_NAME" "${KAITO_NODE_LABEL_KEY}=${KAITO_NODE_LABEL_VALUE}" --overwrite

log "KAITO is installed. To deploy a preset model, apply manifests/kaito-workspace-example.yaml:"
log "  kubectl apply -f manifests/kaito-workspace-example.yaml"
