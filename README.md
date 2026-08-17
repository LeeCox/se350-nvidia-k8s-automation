# SE350 NVIDIA Kubernetes Automation

Automation for bringing up an Ubuntu 24.04 bare-metal Kubernetes node with an NVIDIA A2 GPU and deploying local language models through K3s, the NVIDIA GPU Operator, KAITO, and OpenAI-compatible inference APIs.

The primary tested workload is **NVIDIA Nemotron 3 Nano 4B BF16**, an agent-capable model with tool-calling support that fits the A2 after small-GPU vLLM tuning.

## Architecture

```text
Ubuntu 24.04 bare metal
  -> NVIDIA driver
  -> K3s
  -> NVIDIA GPU Operator
  -> KAITO v0.11 BYO GPU-node mode
  -> Nemotron 3 Nano 4B via vLLM
  -> OpenAI-compatible API
  -> PowerShell chat or Node.js MCP agent runner
```

The node has one NVIDIA A2 GPU with 16 GB physical VRAM, approximately 14.6 GB usable by the workload.

## Requirements

- Ubuntu 24.04 LTS on the GPU node
- NVIDIA A2 GPU
- Working network access to Ubuntu packages, Helm repositories, container registries, and Hugging Face
- A non-root user with `sudo`
- Windows, Linux, or macOS workstation for remote administration
- SSH key access if running the automation remotely

The scripts assume a single-node K3s cluster and a single GPU. They are intended for a lab environment, not production hardening.

## Quick Start

### 1. Prepare configuration

On the Ubuntu node:

```bash
cp config.env.example config.env
nano config.env
```

`config.env` is ignored by Git. Keep Hugging Face tokens and other secrets there, never in `config.env.example`.

### 2. Run the base installation

```bash
chmod +x run-all.sh scripts/*.sh
./run-all.sh
```

The numbered scripts run in this order:

1. Host preparation
2. NVIDIA driver installation
3. K3s installation
4. Helm installation
5. NVIDIA GPU Operator installation
6. GPU validation and KAITO installation
7. Dynamo evaluation deployment
8. TGI model deployment
9. Remote management setup

`run-all.sh` does not apply a KAITO Workspace because a Workspace claims the node's only GPU. Model deployment is a separate deliberate step.

### 3. Deploy Nemotron through KAITO

After `06-install-kaito.sh` has completed:

```bash
bash scripts/deploy-kaito-model.sh
```

The default model is:

```text
nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16
```

Check status:

```bash
export KUBECONFIG="$HOME/.kube/config"
kubectl get workspace workspace-nemotron-3-nano-4b
kubectl get pods -A
```

A successful deployment reports `STATE: Ready`, `INFERENCEREADY: True`, and `WORKSPACESUCCEEDED: True`.

## Nemotron 3.5 Lightning

Nemotron 3.5 Lightning 30B-A3B is not suitable for this A2 node. The model has 30B total parameters and requires substantially more memory and compute than the A2 provides, even with quantization. The 4B Nemotron 3 Nano model is the practical agentic model for this hardware.

## Access the API

KAITO creates a ClusterIP service. From the Ubuntu node, find its address:

```bash
export KUBECONFIG="$HOME/.kube/config"
kubectl get svc workspace-nemotron-3-nano-4b
```

For reliable workstation access, use a two-hop forward. On the Ubuntu node, start a Kubernetes port-forward:

```bash
kubectl port-forward --address 127.0.0.1 \
  svc/workspace-nemotron-3-nano-4b 18000:80
```

In a second workstation terminal, forward the node-local port:

```powershell
ssh -N -o ServerAliveInterval=30 `
  -L 8000:127.0.0.1:18000 `
  <ubuntu-ssh-host>
```

The API is then available at:

```text
http://127.0.0.1:8000/v1
```

Verify it:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/v1/models |
  ConvertTo-Json -Depth 5
```

## Simple Terminal Chat

The PowerShell client includes a bounded `get_local_time` tool:

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File .\scripts\chat-nemotron.ps1
```

The client executes only the explicitly implemented tools. It does not grant Nemotron arbitrary PowerShell or shell access.

## MCP Agent Mode

The Node.js MCP runner discovers tools from configured MCP servers and forwards them to Nemotron. It then executes returned tool calls and sends the results back to the model.

Install dependencies:

```powershell
npm install
```

Create the local configuration:

```powershell
Copy-Item mcp.config.example.json mcp.config.json
```

Update the kubeconfig path in `mcp.config.json`. The local `mcp.config.json` and `mcp.kubeconfig` files are ignored by Git.

Start the agent:

```powershell
$env:OPENAI_BASE_URL = "http://127.0.0.1:8000/v1"
$env:OPENAI_API_KEY = "EMPTY"
npm run chat -- mcp.config.json
```

The starter configuration uses `kubernetes-mcp-server` in read-only mode with destructive operations disabled. It was tested against the live cluster with 14 discovered Kubernetes tools.

Example prompt:

```text
List the pods in the default namespace and tell me whether the Nemotron workspace pod is Ready.
```

## NVIDIA NeMo Agent Toolkit

For a NVIDIA-maintained agent runtime, the Ubuntu node can run the **NeMo Agent Toolkit** as
a CPU-side orchestrator. It uses the local Nemotron OpenAI-compatible endpoint for inference and
the maintained Kubernetes MCP server for read-only cluster tools. It does not consume another GPU.

The tested workflow is in [nat-kubernetes-workflow.yml](nat-kubernetes-workflow.yml). The node setup
uses Python 3.12, `uv`, `nvidia-nat[mcp]`, `nvidia-nat-langchain`, and the Kubernetes MCP binary.

The current workflow uses native tool calling, limits the available Kubernetes tools, and disables
destructive Kubernetes operations. The A2's 8K context window makes tool allowlists important.

On the Ubuntu node, after the model Workspace is ready:

```bash
curl -fsSL https://astral.sh/uv/install.sh | sh
uv venv --python 3.12 ~/nemo-agent-toolkit-env
uv pip install --python ~/nemo-agent-toolkit-env/bin/python \
  'nvidia-nat[mcp]' nvidia-nat-langchain

mkdir -p ~/bin
curl -fsSL \
  https://github.com/containers/kubernetes-mcp-server/releases/download/v0.0.66/kubernetes-mcp-server-linux-amd64 \
  -o ~/bin/kubernetes-mcp-server
chmod +x ~/bin/kubernetes-mcp-server

export NEMOTRON_BASE_URL="http://$(kubectl get svc workspace-nemotron-3-nano-4b -o jsonpath='{.spec.clusterIP}')/v1"
export OPENAI_API_KEY=EMPTY
~/nemo-agent-toolkit-env/bin/nat run \
  --config_file ~/nat-kubernetes-workflow.yml \
  --input "List all pods in the gpu-operator namespace and summarize their health."
```

For hosted NVIDIA models and hosted agentic skills from `build.nvidia.com`, use the same NAT
workflow pattern with an NVIDIA API key and the hosted base URL. The local A2 remains the
tool-orchestration and Nemotron Nano path; large hosted models should not be downloaded to the A2.

## Production Web Chat Portal

The web portal runs inside K3s and calls Nemotron through its ClusterIP service:

```text
Browser -> Traefik HTTPS -> web-chat pod
                          -> workspace-nemotron-3-nano-4b.default.svc.cluster.local
                          -> kubernetes-mcp-server (stdio child process)
                          -> in-cluster Kubernetes API
```

The pod does not contain SSH, `kubectl`, or a general-purpose command tool. It advertises only
`kubernetes_pods_list` to Nemotron, forces that call to the `default` namespace, starts
`kubernetes-mcp-server` with `--read-only` and `--disable-destructive`, and uses a namespace Role
that grants only `get` and `list` on pods. The host NeMo Agent Toolkit installation remains
available for CLI workflows; the portal uses the same MCP/Nemotron orchestration pattern without
exposing the NAT CLI or host access to web requests.

### Build and deploy on `se350ainode`

Copy or clone this repository onto the node, then run:

```bash
cd ~/se350-nvidia-k8s-automation
bash scripts/deploy-web-chat-k3s.sh
```

Docker is not required. The deployment script:

1. Starts a short-lived Kaniko Job in K3s.
2. Builds the image from the local repository through a read-only `hostPath`.
3. Writes a Docker image archive under `.build/`.
4. Imports the archive into K3s containerd with `k3s ctr images import`.
5. Creates the portal token and a dedicated self-signed TLS certificate on first deployment.
6. Applies the immutable image tag atomically and waits for rollout.
7. Removes the build archive and Kaniko Job.

An optional immutable tag can be supplied:

```bash
bash scripts/deploy-web-chat-k3s.sh 2026-08-16.1
```

The deployment uses `imagePullPolicy: Never`; every node that might run the pod must have the image
imported. This cluster is intentionally single-node.

### Access

Open:

```text
https://192.168.1.209/
```

Traefik serves a dedicated self-signed certificate with `192.168.1.209` in its subject alternative
names. Import `web-chat-tls`'s `tls.crt` into the management workstation's trusted root store, or
accept the browser warning after verifying the certificate fingerprint on the node. Plain HTTP is
not routed to the portal.

Export and inspect the public certificate:

```bash
sudo k3s kubectl get secret web-chat-tls -n web-chat \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > web-chat-tls.crt
openssl x509 -in web-chat-tls.crt -noout -fingerprint -sha256 -subject -ext subjectAltName
```

Retrieve the access token on the node:

```bash
sudo k3s kubectl get secret web-chat-auth -n web-chat \
  -o jsonpath='{.data.token}' | base64 -d
echo
```

Paste it into the portal. The browser keeps it in `sessionStorage`, not in a URL or persistent local
storage. To rotate it:

```bash
TOKEN="$(openssl rand -base64 36 | tr -d '\n')"
sudo k3s kubectl create secret generic web-chat-auth -n web-chat \
  --from-literal="token=${TOKEN}" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset TOKEN
sudo k3s kubectl rollout restart deployment/web-chat -n web-chat
sudo k3s kubectl rollout status deployment/web-chat -n web-chat
```

### Validate

```bash
sudo k3s kubectl get deployment,pod,service,networkpolicy -n web-chat -o wide
sudo k3s kubectl auth can-i \
  --as=system:serviceaccount:web-chat:web-chat list pods -n default
sudo k3s kubectl auth can-i \
  --as=system:serviceaccount:web-chat:web-chat list secrets -n default
curl --cacert /path/to/web-chat-tls.crt -fsS https://192.168.1.209/healthz

TOKEN="$(sudo k3s kubectl get secret web-chat-auth -n web-chat \
  -o jsonpath='{.data.token}' | base64 -d)"
curl --cacert /path/to/web-chat-tls.crt -fsS https://192.168.1.209/api/chat \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"List the live pods in the default namespace and summarize readiness."}]}'
unset TOKEN
```

Expected RBAC results are `yes` for listing pods and `no` for listing secrets. A successful tool
request includes a non-empty `toolActivity` array.

### Operations

```bash
sudo k3s kubectl logs -n web-chat deployment/web-chat
sudo k3s kubectl rollout restart deployment/web-chat -n web-chat
sudo k3s kubectl delete -f manifests/web-chat.yaml
```

Traefik exposes HTTPS on the node's management address. API requests require the portal token, are
rate-limited in-process, and have bounded request, conversation, model timeout, and tool-call limits.
K3s uses Flannel by default, so verify that the selected cluster network policy backend enforces the
included `NetworkPolicy`; the TLS, token, and RBAC controls remain effective even when network policy
enforcement is unavailable.

## GPU Constraints

The A2 has one GPU, so only one model workload should claim `nvidia.com/gpu: 1` at a time. Dynamo, TGI, and KAITO are separate workloads and cannot all run simultaneously on this node.

The Nemotron Workspace uses an inference ConfigMap with settings that are important for the A2:

```yaml
vllm:
  enforce-eager: true
  gpu-memory-utilization: 0.85
  max-model-len: 8192
  max-num-seqs: 4
  tool-call-parser: qwen3_coder
  additional-config: '{"enable_auto_tool_choice": true}'
```

`enforce-eager` avoids CUDA graph memory overhead that caused the model to run out of VRAM during startup.

## Important KAITO Details

- KAITO must run in BYO mode with both `featureGates.disableNodeAutoProvisioning=true` and `nodeProvisioner=byo`.
- KAITO Workspace `resource` and `inference` fields are top-level fields in the deployed CRD schema; they are not nested under `spec`.
- Set `KUBECONFIG` explicitly to the user's kubeconfig when running remote commands. K3s otherwise falls back to the root-only `/etc/rancher/k3s/k3s.yaml`.
- A first model startup downloads approximately 7.4 GiB and performs Mamba/Triton warmup. Allow several minutes before judging readiness.

## Repository Layout

```text
config.env.example
FAQ.md
lib/common.sh
manifests/
  kaito-workspace-nemotron.yaml
  kaito-workspace-example.yaml
  dynamo-deployment.yaml
  hf-model-deployment.yaml
  web-chat.yaml
public/
  index.html
  app.js
  styles.css
scripts/
  00-prepare-host.sh
  01-install-nvidia-driver.sh
  02-install-k3s.sh
  03-install-helm.sh
  04-install-gpu-operator.sh
  05-validate-gpu.sh
  06-install-kaito.sh
  07-deploy-dynamo.sh
  08-deploy-hf-model.sh
  09-setup-remote-management.sh
  build-web-chat-k3s.sh
  deploy-web-chat-k3s.sh
  deploy-kaito-model.sh
  chat-nemotron.ps1
Dockerfile
mcp-agent.mjs
mcp.config.example.json
package.json
run-all.sh
web-chat-server.mjs
```

See [FAQ.md](FAQ.md) for configuration details and troubleshooting notes.

## License and Model Terms

This repository contains automation code. The Nemotron model is governed by NVIDIA's model license and terms published with the Hugging Face model card. Review those terms before using the model beyond personal lab evaluation.
