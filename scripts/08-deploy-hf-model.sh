#!/usr/bin/env bash
# Deploys a Hugging Face model using the Text Generation Inference (TGI) server.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd kubectl
require_cmd envsubst

export HF_NAMESPACE="${HF_NAMESPACE:-dynamo}"
export HF_MODEL_ID="${HF_MODEL_ID:-microsoft/Phi-3-mini-4k-instruct}"
export TGI_IMAGE="${TGI_IMAGE:-ghcr.io/huggingface/text-generation-inference:latest}"

kubectl create namespace "$HF_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${HF_TOKEN:-}" ]]; then
  log "Creating/updating Hugging Face token secret"
else
  warn "HF_TOKEN is not set. Fine for public models; required for gated ones."
fi
kubectl create secret generic hf-secret \
  --from-literal=token="${HF_TOKEN:-}" \
  -n "$HF_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying Hugging Face model deployment (model: $HF_MODEL_ID)"
envsubst < "$SCRIPT_DIR/../manifests/hf-model-deployment.yaml" | kubectl apply -f -
envsubst < "$SCRIPT_DIR/../manifests/hf-model-service.yaml" | kubectl apply -f -

log "Waiting for rollout (first run downloads model weights and can take a while)"
wait_for_rollout deployment hf-model "$HF_NAMESPACE" 20m

kubectl get pods -n "$HF_NAMESPACE"
log "Test with:"
log "  kubectl run -it --rm curl --image=curlimages/curl -n $HF_NAMESPACE --restart=Never -- curl -s http://hf-model/generate -X POST -H 'Content-Type: application/json' -d '{\"inputs\":\"Hello\"}'"
