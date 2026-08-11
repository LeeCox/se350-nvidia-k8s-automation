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
  deploy-kaito-model.sh
  chat-nemotron.ps1
mcp-agent.mjs
mcp.config.example.json
package.json
run-all.sh
```

See [FAQ.md](FAQ.md) for configuration details and troubleshooting notes.

## License and Model Terms

This repository contains automation code. The Nemotron model is governed by NVIDIA's model license and terms published with the Hugging Face model card. Review those terms before using the model beyond personal lab evaluation.
