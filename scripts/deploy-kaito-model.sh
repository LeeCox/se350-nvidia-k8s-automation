#!/usr/bin/env bash
# Deploys a model through KAITO by applying a Workspace custom resource. Unlike the numbered
# 00-09 scripts, this one is not part of run-all.sh: applying a Workspace is a deliberate,
# separate action (see FAQ.md) since it also claims the node's only GPU.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd kubectl
require_cmd envsubst

export KAITO_WORKSPACE_NAME="${KAITO_WORKSPACE_NAME:-workspace-nemotron-3-nano-4b}"
export KAITO_MODEL_PRESET="${KAITO_MODEL_PRESET:-nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16}"
export KAITO_NODE_LABEL_KEY="${KAITO_NODE_LABEL_KEY:-apps}"
export KAITO_NODE_LABEL_VALUE="${KAITO_NODE_LABEL_VALUE:-llm-inference}"

# The A2 is a single GPU. Dynamo (07) and the TGI hf-model deployment (08) also request
# nvidia.com/gpu: 1, so only one GPU-consuming workload can be Running at a time - the others
# will sit Pending until scaled down.
if kubectl get deployment dynamo -n "${DYNAMO_NAMESPACE:-dynamo}" >/dev/null 2>&1 || \
   kubectl get deployment hf-model -n "${HF_NAMESPACE:-dynamo}" >/dev/null 2>&1; then
  warn "Dynamo and/or the TGI hf-model Deployment already exist and also claim the A2's only GPU."
  warn "Scale them down first or the KAITO workspace pod will sit Pending waiting for a free GPU:"
  warn "  kubectl scale deployment dynamo -n ${DYNAMO_NAMESPACE:-dynamo} --replicas=0"
  warn "  kubectl scale deployment hf-model -n ${HF_NAMESPACE:-dynamo} --replicas=0"
fi

log "Applying KAITO Workspace $KAITO_WORKSPACE_NAME (preset: $KAITO_MODEL_PRESET)"
envsubst < "$SCRIPT_DIR/../manifests/kaito-workspace-nemotron.yaml" | kubectl apply -f -

log "Waiting for the workspace to become ready (first run downloads model weights, can take a while)"
for _ in $(seq 1 80); do
  READY="$(kubectl get workspace "$KAITO_WORKSPACE_NAME" -o jsonpath='{.status.conditions[?(@.type=="WorkspaceSucceeded")].status}' 2>/dev/null || true)"
  [[ "$READY" == "True" ]] && break
  sleep 15
done
kubectl get workspace "$KAITO_WORKSPACE_NAME"

CLUSTERIP="$(kubectl get svc "$KAITO_WORKSPACE_NAME" -o jsonpath='{.spec.clusterIPs[0]}' 2>/dev/null || true)"
log "Test with:"
log "  kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- curl -s http://${CLUSTERIP:-<service-cluster-ip>}/v1/chat/completions \\"
log "    -X POST -H 'Content-Type: application/json' \\"
log "    -d '{\"model\":\"${KAITO_MODEL_PRESET}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
