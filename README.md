# SE350 NVIDIA Kubernetes AI Harness

This repository provisions a single-node NVIDIA AI environment on a Lenovo SE350 and provides a
secure harness for local model inference and bounded Kubernetes tool use.

The harness combines:

- Ubuntu 24.04 and an NVIDIA A2 GPU
- K3s and containerd
- NVIDIA GPU Operator
- KAITO in bring-your-own-node mode
- NVIDIA Nemotron 3 Nano 4B served through an OpenAI-compatible API
- NVIDIA NeMo Agent Toolkit and Model Context Protocol (MCP) integrations
- An HTTPS web portal with a constrained, read-only Kubernetes tool

## Architecture

```text
Management browser
  |
  | HTTPS + bearer token
  v
K3s Traefik ingress
  |
  v
web-chat pod
  |-- OpenAI chat requests --> Nemotron ClusterIP service --> KAITO/vLLM --> NVIDIA A2
  |
  `-- stdio MCP client --> kubernetes-mcp-server --> Kubernetes API
                                                `--> default namespace pods: get/list only
```

The model and portal communicate entirely over in-cluster services. The model API is not exposed
directly to the management network. The portal does not contain SSH, `kubectl`, or a general-purpose
shell tool.

## Repository Components

| Component | Purpose |
| --- | --- |
| `run-all.sh` | Runs the numbered host and Kubernetes bootstrap scripts |
| `scripts/00-prepare-host.sh` | Prepares Ubuntu packages and host settings |
| `scripts/01-install-nvidia-driver.sh` | Installs the NVIDIA driver |
| `scripts/02-install-k3s.sh` | Installs single-node K3s |
| `scripts/03-install-helm.sh` | Installs Helm |
| `scripts/04-install-gpu-operator.sh` | Installs NVIDIA GPU Operator |
| `scripts/05-validate-gpu.sh` | Validates GPU availability in Kubernetes |
| `scripts/06-install-kaito.sh` | Installs KAITO in bring-your-own-node mode |
| `scripts/deploy-kaito-model.sh` | Creates the Nemotron KAITO Workspace |
| `scripts/build-web-chat-k3s.sh` | Builds the portal with Kaniko and imports it into K3s containerd |
| `scripts/deploy-web-chat-k3s.sh` | Deploys and exposes the HTTPS portal |
| `manifests/kaito-workspace-nemotron.yaml` | Defines the KAITO model workspace and vLLM settings |
| `manifests/web-chat.yaml` | Defines the portal workload, RBAC, service, ingress, and network policy |
| `web-chat-server.mjs` | Implements the portal API, model loop, and bounded MCP execution |
| `nat-kubernetes-workflow.yml` | Defines the NeMo Agent Toolkit Kubernetes workflow |
| `mcp-agent.mjs` | Provides a local Node.js MCP client for development and administration |

The Dynamo and Hugging Face TGI manifests are alternative inference paths. They are not deployed
alongside the KAITO Workspace because the node has one GPU.

## Requirements

- Lenovo SE350 or equivalent Ubuntu 24.04 x86-64 host
- NVIDIA A2 GPU with 16 GB VRAM
- Internet access to Ubuntu, Helm, container, npm, GitHub, and model registries
- A non-root account with passwordless or interactive `sudo`
- SSH key access for remote administration
- Access to the trusted management network

The manifests assume:

- One K3s server node
- K3s containerd as the container runtime
- Traefik enabled
- The `local-path` storage class
- Node management address `192.168.1.209`

## Configure the Harness

Create the local configuration file on the Ubuntu node:

```bash
cp config.env.example config.env
nano config.env
```

`config.env` is excluded from Git. Store model registry tokens and other secrets only in this file
or in Kubernetes Secrets.

Make the scripts executable:

```bash
chmod +x run-all.sh scripts/*.sh
```

## Bootstrap the Node

For the KAITO and web-portal harness, run the platform scripts followed by remote-management setup:

```bash
for step in \
  scripts/00-prepare-host.sh \
  scripts/01-install-nvidia-driver.sh \
  scripts/02-install-k3s.sh \
  scripts/03-install-helm.sh \
  scripts/04-install-gpu-operator.sh \
  scripts/05-validate-gpu.sh \
  scripts/06-install-kaito.sh \
  scripts/09-setup-remote-management.sh
do
  bash "$step"
done
```

This sequence installs the host prerequisites, NVIDIA driver, K3s, Helm, GPU Operator, KAITO, and
management utilities without starting a model workload.

`run-all.sh` also runs the Dynamo and Hugging Face TGI deployment scripts. Use it only when those
alternative inference paths are required. Dynamo, TGI, and the KAITO Workspace each request the
node's only GPU and must not run concurrently.

## Deploy the Model

Deploy the Nemotron Workspace:

```bash
bash scripts/deploy-kaito-model.sh
```

The default model is:

```text
nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16
```

The Workspace configures vLLM for the A2:

```yaml
vllm:
  enforce-eager: true
  gpu-memory-utilization: 0.85
  max-model-len: 8192
  max-num-seqs: 4
  tool-call-parser: qwen3_coder
  additional-config: '{"enable_auto_tool_choice": true}'
```

Check the model:

```bash
export KUBECONFIG="$HOME/.kube/config"
kubectl get workspace workspace-nemotron-3-nano-4b
kubectl get pod workspace-nemotron-3-nano-4b-0
kubectl get service workspace-nemotron-3-nano-4b
```

The Workspace is available when:

- `STATE` is `Ready`
- `INFERENCEREADY` is `True`
- `WORKSPACESUCCEEDED` is `True`
- The model pod is `1/1 Running`

## Deploy the Web Portal

Run on `se350ainode` from the repository root:

```bash
bash scripts/deploy-web-chat-k3s.sh
```

An immutable image tag can be supplied:

```bash
bash scripts/deploy-web-chat-k3s.sh 2026-08-16.1
```

Docker is not required. The deployment process:

1. Runs a short-lived Kaniko Job in K3s.
2. Mounts the repository into the build pod as read-only input.
3. Builds a container image archive under `.build/`.
4. Imports the archive with `k3s ctr images import`.
5. Creates the portal access token if it does not exist.
6. Creates an IP-address TLS certificate if it does not exist.
7. Applies the immutable image tag and waits for rollout.
8. Removes the image archive and build Job.

The portal is available at:

```text
https://192.168.1.209/
```

Plain HTTP does not route to the application.

### Retrieve the Access Token

From a management workstation:

```powershell
ssh se350ainode "sudo k3s kubectl get secret web-chat-auth -n web-chat -o jsonpath='{.data.token}' | base64 -d; echo"
```

Paste the token into the portal. The browser keeps it in `sessionStorage`, so it is cleared when the
browser session ends.

### Trust the TLS Certificate

Export the public certificate:

```bash
sudo k3s kubectl get secret web-chat-tls -n web-chat \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > web-chat-tls.crt
openssl x509 -in web-chat-tls.crt \
  -noout -fingerprint -sha256 -subject -ext subjectAltName
```

Verify the fingerprint and import `web-chat-tls.crt` into the management workstation's trusted root
store. The certificate contains `192.168.1.209` as an IP subject alternative name.

## Request Flow

For a normal model request:

1. The browser sends the conversation to `/api/chat`.
2. The portal validates the bearer token, request size, message count, roles, and content length.
3. The portal sends the bounded conversation to the Nemotron ClusterIP service.
4. Nemotron returns a response to the portal.
5. The portal returns the response to the browser.

For a Kubernetes status request:

1. The portal advertises only `kubernetes_pods_list` to Nemotron.
2. Nemotron may request that tool.
3. The portal rejects any other tool name or caller-controlled tool arguments.
4. The portal maps the request to `pods_list_in_namespace` with namespace fixed to `default`.
5. `kubernetes-mcp-server` calls the Kubernetes API using the pod's service account.
6. The tool result is returned to Nemotron for a final response.

Tool execution is limited to one tool call per round and three model rounds.

## Security Boundaries

The portal uses multiple independent controls:

- HTTPS termination through Traefik
- Bearer token stored in a Kubernetes Secret
- Constant-time token comparison
- In-process request rate limiting
- 64 KiB request limit
- Conversation message and character limits
- 120-second model request timeout
- Non-root container user
- Read-only root filesystem
- Dropped Linux capabilities
- Runtime-default seccomp profile
- CPU and memory limits
- `kubernetes-mcp-server --read-only --disable-destructive`
- A fixed MCP tool allowlist
- Namespace-fixed tool arguments
- Kubernetes Role permitting only pod `get` and `list` in `default`
- NetworkPolicy restricting ingress and required egress paths

The service account cannot list Secrets, modify resources, execute in pods, read logs, or access
other namespaces.

## NeMo Agent Toolkit Interface

The NeMo Agent Toolkit workflow provides a host-side orchestration interface for administrators. It
uses the same local Nemotron API and Kubernetes MCP server without consuming another GPU.

Install the runtime on the node:

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
```

Run the workflow:

```bash
export NEMOTRON_BASE_URL="http://$(kubectl get service \
  workspace-nemotron-3-nano-4b -o jsonpath='{.spec.clusterIP}')/v1"
export OPENAI_API_KEY=EMPTY
~/nemo-agent-toolkit-env/bin/nat run \
  --config_file ~/nat-kubernetes-workflow.yml \
  --input "List the pods in the default namespace and summarize readiness."
```

The workflow configuration controls which MCP tools are available to the agent.

## Local MCP Client

The Node.js client is an administrative and development interface for configured MCP servers.

```powershell
npm install
Copy-Item mcp.config.example.json mcp.config.json
$env:OPENAI_BASE_URL = "http://127.0.0.1:8000/v1"
$env:OPENAI_API_KEY = "EMPTY"
npm run chat -- mcp.config.json
```

Keep `mcp.config.json` and `mcp.kubeconfig` local. Both are excluded from Git. Restrict configured
servers with read-only flags, tool allowlists, and least-privilege kubeconfig credentials.

## Direct API Access

The model service is a ClusterIP. For administrative access, forward it through the Kubernetes API:

```bash
kubectl port-forward --address 127.0.0.1 \
  service/workspace-nemotron-3-nano-4b 8000:80
```

The API is then available on the node at:

```text
http://127.0.0.1:8000/v1
```

Do not expose the model service directly on the management network.

## Validation

Check the portal resources:

```bash
sudo k3s kubectl get deployment,pod,service,ingress,networkpolicy \
  -n web-chat -o wide
```

Confirm the service-account boundary:

```bash
sudo k3s kubectl auth can-i \
  --as=system:serviceaccount:web-chat:web-chat \
  list pods -n default

sudo k3s kubectl auth can-i \
  --as=system:serviceaccount:web-chat:web-chat \
  list secrets -n default
```

The expected results are `yes` for pods and `no` for Secrets.

Check health over HTTPS:

```bash
curl --cacert web-chat-tls.crt -fsS \
  https://192.168.1.209/healthz
```

Validate a model and MCP request:

```bash
TOKEN="$(sudo k3s kubectl get secret web-chat-auth -n web-chat \
  -o jsonpath='{.data.token}' | base64 -d)"

curl --cacert web-chat-tls.crt -fsS \
  https://192.168.1.209/api/chat \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{"messages":[{"role":"user","content":"List the live pods in the default namespace and summarize readiness."}]}'

unset TOKEN
```

A tool-assisted response includes:

```json
{
  "toolActivity": [
    {
      "tool": "kubernetes_pods_list",
      "namespace": "default"
    }
  ]
}
```

## Operations

View portal status and logs:

```bash
sudo k3s kubectl get deployment,pod -n web-chat
sudo k3s kubectl logs -n web-chat deployment/web-chat
```

Rotate the access token:

```bash
TOKEN="$(openssl rand -base64 36 | tr -d '\n')"
sudo k3s kubectl create secret generic web-chat-auth \
  -n web-chat \
  --from-literal="token=${TOKEN}" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset TOKEN

sudo k3s kubectl rollout restart deployment/web-chat -n web-chat
sudo k3s kubectl rollout status deployment/web-chat -n web-chat
```

Redeploy the portal:

```bash
bash scripts/deploy-web-chat-k3s.sh
```

Remove the portal:

```bash
sudo k3s kubectl delete -f manifests/web-chat.yaml
sudo k3s kubectl delete secret web-chat-auth web-chat-tls -n web-chat
```

## Constraints

- The node has one GPU, so only one model workload can run at a time.
- Images are imported into local K3s containerd and are available only on that node.
- The self-signed TLS certificate must be trusted by management clients and rotated before expiry.
- In-process rate-limit state resets when the portal pod restarts.
- NetworkPolicy enforcement depends on the K3s networking backend.
- The portal intentionally exposes only pod listing in the `default` namespace.

## License and Model Terms

This repository contains automation and harness code. Model artifacts are governed by the license
and terms published with the selected model. Review those terms before use.
