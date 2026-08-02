#!/usr/bin/env bash
# Installs K3s as a single-node Kubernetes control plane and sets up a user kubeconfig.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd nvidia-smi
nvidia-smi >/dev/null || die "nvidia-smi failed. Fix the NVIDIA driver before installing Kubernetes."

if command -v k3s >/dev/null 2>&1; then
  log "K3s is already installed: $(k3s --version | head -n1)"
else
  log "Installing K3s"
  curl -sfL https://get.k3s.io | sh -
fi

log "Waiting for the K3s service to be active"
sudo systemctl is-active --quiet k3s || die "k3s.service is not active. Check: sudo journalctl -u k3s -e"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
sudo chown "$(id -u)":"$(id -g)" "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"
log "Waiting for the node to reach Ready"
for _ in $(seq 1 30); do
  # Not piped into `grep -q` - see the SIGPIPE/pipefail note in 00-prepare-host.sh.
  if grep -q ' Ready' <<<"$(kubectl get nodes --no-headers 2>/dev/null)"; then
    break
  fi
  sleep 5
done
kubectl get nodes -o wide
