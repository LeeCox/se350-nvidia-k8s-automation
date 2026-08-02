#!/usr/bin/env bash
# Installs Helm using the official get-helm-3 script (self-verifies checksums).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

if command -v helm >/dev/null 2>&1; then
  log "Helm already installed: $(helm version --short)"
  exit 0
fi

log "Installing Helm"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh
rm -f /tmp/get_helm.sh

helm version
