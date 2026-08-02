# Shared helpers sourced by every script in this repo. Not meant to be executed directly.

# K3s installs kubectl as a symlink to the k3s binary, and that shim falls back to
# /etc/rancher/k3s/k3s.yaml - which is root-only, so kubectl fails for a normal user even though
# 02-install-k3s.sh wrote a perfectly good kubeconfig into the home directory. Point at that one.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

log()  { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '\n[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."
}

confirm() {
  local prompt="${1:-Continue?} [y/N] " reply
  read -r -p "$prompt" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

wait_for_rollout() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-300s}"
  kubectl rollout status "$kind/$name" -n "$ns" --timeout="$timeout"
}
