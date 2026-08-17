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
OUTPUT_DIR="${ROOT_DIR}/.build"
JOB_NAME="web-chat-image-build"

mkdir -p "$OUTPUT_DIR"
rm -f "${OUTPUT_DIR}/web-chat.tar"

sudo k3s kubectl delete job "$JOB_NAME" -n web-chat --ignore-not-found --wait=true
sudo k3s kubectl create namespace web-chat --dry-run=client -o yaml | sudo k3s kubectl apply -f -

cat <<EOF | sudo k3s kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: web-chat
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:v1.23.2-debug
          args:
            - --context=dir:///workspace
            - --dockerfile=/workspace/Dockerfile
            - --destination=${IMAGE}
            - --no-push
            - --tar-path=/output/web-chat.tar
            - --snapshot-mode=redo
          volumeMounts:
            - name: context
              mountPath: /workspace
              readOnly: true
            - name: output
              mountPath: /output
      volumes:
        - name: context
          hostPath:
            path: ${ROOT_DIR}
            type: Directory
        - name: output
          hostPath:
            path: ${OUTPUT_DIR}
            type: Directory
EOF

if ! sudo k3s kubectl wait -n web-chat --for=condition=complete "job/${JOB_NAME}" --timeout=15m; then
  sudo k3s kubectl logs -n web-chat "job/${JOB_NAME}" --all-containers
  exit 1
fi

sudo k3s kubectl logs -n web-chat "job/${JOB_NAME}" --all-containers
test -s "${OUTPUT_DIR}/web-chat.tar"
sudo k3s ctr images import "${OUTPUT_DIR}/web-chat.tar"
sudo k3s ctr images check "name==${IMAGE}"
rm -f "${OUTPUT_DIR}/web-chat.tar"
sudo k3s kubectl delete job "$JOB_NAME" -n web-chat --ignore-not-found --wait=true

printf '%s\n' "$IMAGE"
