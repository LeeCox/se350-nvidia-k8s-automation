#!/usr/bin/env bash
# Installs the recommended NVIDIA driver via ubuntu-drivers and verifies it with nvidia-smi.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  log "NVIDIA driver already installed and working:"
  nvidia-smi
  exit 0
fi

require_cmd sudo
require_cmd ubuntu-drivers

log "Installing the recommended NVIDIA driver (this can take a few minutes)"
sudo ubuntu-drivers autoinstall

warn "A reboot is required to load the new driver."
if [[ "${AUTO_REBOOT:-false}" == "true" ]]; then
  log "AUTO_REBOOT=true, rebooting now"
  sudo reboot
else
  log "Reboot the host, then re-run this script to verify with nvidia-smi:"
  log "  sudo reboot"
  log "  ./scripts/01-install-nvidia-driver.sh"
  exit 0
fi
