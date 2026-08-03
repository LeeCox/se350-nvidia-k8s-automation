#!/usr/bin/env bash
# Deploys NVIDIA Dynamo's frontend + a single vLLM worker as a one-GPU workload.
#
# NOTE: Dynamo's own docs state that for a single model on a single GPU, the inference
# engine alone (vLLM/SGLang/TensorRT-LLM) is usually sufficient - Dynamo's value
# (disaggregated serving, KV-aware routing, multi-node autoscaling) targets multi-GPU
# and multi-node deployments. This script runs Dynamo's frontend and one vLLM worker in
# a single pod for evaluation purposes on the SE350's single A2 GPU.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd kubectl
require_cmd envsubst

export DYNAMO_NAMESPACE="${DYNAMO_NAMESPACE:-dynamo}"
export DYNAMO_IMAGE="${DYNAMO_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0}"
export DYNAMO_MODEL_ID="${DYNAMO_MODEL_ID:-Qwen/Qwen3-0.6B}"
# Advisory only under local-path, but the PVC manifest requires a value.
export MODEL_CACHE_SIZE="${MODEL_CACHE_SIZE:-100Gi}"

kubectl create namespace "$DYNAMO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Applying Dynamo deployment (model: $DYNAMO_MODEL_ID)"
envsubst < "$SCRIPT_DIR/../manifests/dynamo-deployment.yaml" | kubectl apply -f -
envsubst < "$SCRIPT_DIR/../manifests/dynamo-service.yaml" | kubectl apply -f -

log "Waiting for rollout"
wait_for_rollout deployment dynamo "$DYNAMO_NAMESPACE" 10m

kubectl get pods -n "$DYNAMO_NAMESPACE"
log "Test with:"
log "  kubectl run -it --rm curl --image=curlimages/curl -n $DYNAMO_NAMESPACE --restart=Never -- curl -s http://dynamo/v1/models"
