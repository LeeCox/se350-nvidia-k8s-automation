#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'source')"
IMAGE_TAG="${1:-${SOURCE_REVISION}-$(date -u +%Y%m%d%H%M%S)}"
if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid container image tag: ${IMAGE_TAG}" >&2
  exit 2
fi
IMAGE="localhost/web-chat:${IMAGE_TAG}"
NODE_IP="$(hostname -I | awk '{print $1}')"

bash "${ROOT_DIR}/scripts/build-web-chat-k3s.sh" "$IMAGE_TAG"

sudo k3s kubectl create namespace web-chat --dry-run=client -o yaml | sudo k3s kubectl apply -f -
if ! sudo k3s kubectl get secret web-chat-auth -n web-chat >/dev/null 2>&1; then
  TOKEN="$(openssl rand -base64 36 | tr -d '\n')"
  sudo k3s kubectl create secret generic web-chat-auth \
    -n web-chat \
    --from-literal="token=${TOKEN}"
  unset TOKEN
fi

if ! sudo k3s kubectl get secret web-chat-tls -n web-chat >/dev/null 2>&1; then
  CERT_DIR="$(mktemp -d)"
  trap 'rm -f "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt"; rmdir "$CERT_DIR"' EXIT
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 397 \
    -keyout "${CERT_DIR}/tls.key" \
    -out "${CERT_DIR}/tls.crt" \
    -subj "/CN=${NODE_IP}" \
    -addext "subjectAltName=IP:${NODE_IP}"
  sudo k3s kubectl create secret tls web-chat-tls \
    -n web-chat \
    --cert="${CERT_DIR}/tls.crt" \
    --key="${CERT_DIR}/tls.key"
  rm -f "${CERT_DIR}/tls.key" "${CERT_DIR}/tls.crt"
  rmdir "$CERT_DIR"
  trap - EXIT
fi

sed "s|localhost/web-chat:production|${IMAGE}|" "${ROOT_DIR}/manifests/web-chat.yaml" |
  sudo k3s kubectl apply -f -
sudo k3s kubectl rollout status deployment/web-chat -n web-chat --timeout=5m
sudo k3s kubectl get deployment,pod,service,ingress -n web-chat -o wide

echo "Portal URL: https://${NODE_IP}/"
echo "Retrieve the access token with:"
echo "  sudo k3s kubectl get secret web-chat-auth -n web-chat -o jsonpath='{.data.token}' | base64 -d; echo"
