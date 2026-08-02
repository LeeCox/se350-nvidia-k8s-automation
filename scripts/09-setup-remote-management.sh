#!/usr/bin/env bash
# Sets up a standard remote-management stack: SSH check, Tailscale, Cockpit, k9s, Ansible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ -f "$SCRIPT_DIR/../config.env" ]] && source "$SCRIPT_DIR/../config.env"

require_cmd sudo

log "Checking SSH server status"
if systemctl is-active --quiet ssh; then
  log "SSH is active"
else
  warn "SSH is not active. Installing/enabling openssh-server."
  sudo apt-get install -y openssh-server
  sudo systemctl enable --now ssh
fi

if [[ "${ENABLE_TAILSCALE:-true}" == "true" ]] && ! command -v tailscale >/dev/null 2>&1; then
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  log "Run 'sudo tailscale up' to authenticate this host."
else
  log "Tailscale already installed or disabled by config"
fi

if [[ "${ENABLE_COCKPIT:-true}" == "true" ]] && ! systemctl list-unit-files | grep -q '^cockpit.socket'; then
  log "Installing Cockpit"
  sudo apt-get install -y cockpit
  sudo systemctl enable --now cockpit.socket
else
  log "Cockpit already installed or disabled by config"
fi

if ! command -v k9s >/dev/null 2>&1; then
  log "Installing k9s"
  K9S_VERSION="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')"
  curl -fsSL -o /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
  sudo tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
  rm -f /tmp/k9s.tar.gz
else
  log "k9s already installed"
fi

if ! command -v ansible >/dev/null 2>&1; then
  log "Installing Ansible"
  sudo apt-get install -y ansible
else
  log "Ansible already installed"
fi

log "Remote management stack ready."
log "  SSH:        systemctl status ssh"
log "  Tailscale:  sudo tailscale up"
log "  Cockpit:    https://<host>:9090"
log "  k9s:        k9s"
