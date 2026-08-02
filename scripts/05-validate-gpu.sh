#!/usr/bin/env bash
# Runs a throwaway CUDA pod that requests a GPU and prints nvidia-smi from inside the container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd kubectl
require_cmd envsubst

export POD_NAME="gpu-validate-$RANDOM"
MANIFEST="$SCRIPT_DIR/../manifests/gpu-test-pod.yaml"

log "Applying GPU test pod ($POD_NAME)"
envsubst < "$MANIFEST" | kubectl apply -f -

trap 'kubectl delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1' EXIT

log "Waiting for pod to complete"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s pod/"$POD_NAME" || {
  warn "Pod did not reach Succeeded. Current state:"
  kubectl describe pod/"$POD_NAME"
  exit 1
}

log "nvidia-smi output from inside the pod:"
kubectl logs "$POD_NAME"
