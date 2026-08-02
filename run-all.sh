#!/usr/bin/env bash
# Runs the full SE350 + A2 bare-metal Kubernetes bring-up in order.
# Each step checks current state before making changes, so reruns are safe.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

STEPS=(
  scripts/00-prepare-host.sh
  scripts/01-install-nvidia-driver.sh
  scripts/02-install-k3s.sh
  scripts/03-install-helm.sh
  scripts/04-install-gpu-operator.sh
  scripts/05-validate-gpu.sh
  scripts/06-install-kaito.sh
  scripts/07-deploy-dynamo.sh
  scripts/08-deploy-hf-model.sh
  scripts/09-setup-remote-management.sh
)

for step in "${STEPS[@]}"; do
  log "==> Running $step"
  bash "$SCRIPT_DIR/$step"
done

log "All steps complete."
