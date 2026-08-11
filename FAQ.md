# FAQ

## Baseline OS: Ubuntu 24.04 LTS

The scripts target **Ubuntu 24.04 LTS**. It was chosen over 22.04 because, as of
this project's creation (mid-2026), 22.04's standard support window ends April
2027 while 24.04 runs to April 2029 (ESM to 2034), and NVIDIA's GPU Operator
precompiled-driver matrix favors 24.04 on the 6.8 kernel (22.04 falls back to a
slower DKMS build on that same kernel). Both are officially validated for the A2
GPU and Kubernetes 1.32-1.36 on bare metal, so 22.04 remains a fine choice if you
have an existing image/compliance baseline that requires it.

### What about Ubuntu 26.04 LTS?

Checked directly against NVIDIA's GPU Operator platform-support matrix (Aug 2026):
26.04 LTS (released April 2026) is **not yet listed** as a supported OS anywhere
in that matrix - only 22.04 and 24.04 LTS appear. New LTS releases typically take
NVIDIA a few months to certify. 26.04 has the best support lifecycle of the three
(standard support to May 2031), but until it's certified for the GPU Operator,
stay on 24.04. Worth rechecking in a few months.

## Project structure

```
config.env.example        # copy to config.env (gitignored) and edit values
.gitignore
lib/
  common.sh                # shared log/warn/die/require_cmd/confirm/wait_for_rollout helpers
scripts/
  00-prepare-host.sh        # apt packages, Secure Boot check, GPU presence check
  01-install-nvidia-driver.sh
  02-install-k3s.sh
  03-install-helm.sh
  04-install-gpu-operator.sh
  05-validate-gpu.sh        # throwaway CUDA pod + nvidia-smi
  06-install-kaito.sh        # KAITO in BYO-GPU-node mode, labels the node
  07-deploy-dynamo.sh        # Dynamo frontend + 1 vLLM worker, single GPU
  08-deploy-hf-model.sh      # Hugging Face model via TGI
  09-setup-remote-management.sh  # SSH, Tailscale, Cockpit, k9s, Ansible
  deploy-kaito-model.sh      # applies a KAITO Workspace - manual, not run by run-all.sh
  chat-nemotron.ps1          # local OpenAI-compatible chat loop with bounded tool execution
manifests/
  gpu-test-pod.yaml
  kaito-workspace-example.yaml    # reference-only, not auto-applied
  kaito-workspace-nemotron.yaml   # Nemotron 3 Nano 4B preset, applied by deploy-kaito-model.sh
  dynamo-deployment.yaml / dynamo-service.yaml
  hf-model-deployment.yaml / hf-model-service.yaml
run-all.sh                 # runs every script above in numeric order
```

### Why are scripts numbered?

They reflect required install order (driver before Kubernetes, Kubernetes before Helm charts, GPU Operator before any GPU workload, etc). `run-all.sh` just runs them in that order; each script also checks current state, so re-running a single script or the whole set again is safe.

### Why do `lib/common.sh` and `config.env` get sourced by every script?

`common.sh` gives every script the same logging/helper functions. `config.env` (copied from `config.env.example`) centralizes all tunable values so nothing is hardcoded in multiple places. Both sourcing lines are guarded with `[[ -f ... ]] &&`, so scripts still run with built-in defaults if `config.env` hasn't been created yet.

### Why do Dynamo and the Hugging Face model share the `dynamo` namespace?

They both default to the same namespace variable value out of convenience. Set `HF_NAMESPACE` to something else in `config.env` (e.g. `hf-models`) if you want them isolated.

### Why is `manifests/kaito-workspace-example.yaml` not applied by any script?

KAITO's `Workspace` custom resource is how *you* choose which model/preset to deploy. The install script only stands up the controller and labels the node; applying a `Workspace` is a separate, deliberate action left to you.

### How do I deploy a model through KAITO?

Run `bash scripts/deploy-kaito-model.sh`. It applies `manifests/kaito-workspace-nemotron.yaml`
(defaults to the curated `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` preset - an agentic/tool-calling
model sized for the A2's 16GB VRAM) and waits for the Workspace to report ready. Override
`KAITO_WORKSPACE_NAME` / `KAITO_MODEL_PRESET` in `config.env` to deploy a different preset - see
the [presets list](https://kaito-project.github.io/kaito/docs/presets) for curated models, or
pass any HuggingFace model ID supported by vLLM as a best-effort generic preset.

The A2 has one GPU. Dynamo (07) and the TGI `hf-model` deployment (08) also request
`nvidia.com/gpu: 1`, so only one of Dynamo/TGI/KAITO can be `Running` at a time - the script
warns and gives the `kubectl scale --replicas=0` commands to free the GPU if needed.

### How do I use Nemotron as an agent from a terminal?

Keep the SSH tunnel to the KAITO service running, then launch
`powershell -File scripts/chat-nemotron.ps1` in a second terminal. The client supplies a
`get_local_time` function tool, executes the tool when Nemotron requests it, and sends the
result back for the final response. Add tools to `Invoke-Tool` only when their execution
scope is understood; the example intentionally does not grant arbitrary shell access.

---

## Versioning

| Component | Pinned? | Detail |
|---|---|---|
| GPU validation image | ✅ Pinned | `nvidia/cuda:12.4.1-base-ubuntu22.04` |
| Dynamo runtime image | ✅ Pinned | `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0` |
| NVIDIA driver | ❌ Floating | `ubuntu-drivers autoinstall` picks Ubuntu's current recommendation |
| K3s | ❌ Floating | `get.k3s.io` installs the latest stable channel |
| Helm | ❌ Floating | `get-helm-3` installs the latest GitHub release |
| GPU Operator | ❌ Floating (pinnable) | `GPU_OPERATOR_VERSION` is empty by default; set it to pin |
| KAITO | ❌ Floating | no `--version` flag on the `kaito/workspace` chart install |
| TGI (HF model server) | ❌ Floating | `TGI_IMAGE` defaults to the `:latest` tag |
| k9s | ❌ Floating | queries GitHub's `releases/latest` API at runtime |
| Tailscale | ❌ Floating | official install script pulls the current release |
| Ansible / Cockpit | ❌ Floating | whatever version is in the Ubuntu apt repos at run time |

### Why isn't everything pinned?

Convenience for a lab environment — you always get current fixes without maintaining a version list. The tradeoff is that running `run-all.sh` today vs. months from now can install different versions of K3s, Helm, the GPU Operator, KAITO, and TGI.

### How do I pin a version?

- **GPU Operator**: set `GPU_OPERATOR_VERSION` in `config.env` (already wired into `04-install-gpu-operator.sh`).
- **TGI**: set `TGI_IMAGE` in `config.env` to a specific tag instead of `:latest`.
- **K3s / Helm / KAITO / k9s**: not yet wired to a config variable. Ask if you want these added — K3s honors `INSTALL_K3S_VERSION`, Helm's installer honors `DESIRED_VERSION`, KAITO's chart install accepts `--version`, and k9s can skip the GitHub API lookup if given a fixed tag.

---

## Config options (`config.env.example`)

| Variable | Default | Purpose |
|---|---|---|
| `CLUSTER_NAME` | `se350-lab` | Passed to the KAITO chart as `clusterName` |
| `KUBECONFIG_PATH` | `${HOME}/.kube/config` | Where K3s's kubeconfig gets copied for your user |
| `GPU_OPERATOR_NAMESPACE` | `gpu-operator` | Namespace for the GPU Operator install |
| `GPU_OPERATOR_VERSION` | *(empty)* | Set to pin a specific chart version; empty = latest |
| `KAITO_NAMESPACE` | `kaito-workspace` | Namespace for the KAITO controller |
| `KAITO_NODE_LABEL_KEY` / `KAITO_NODE_LABEL_VALUE` | `apps` / `llm-inference` | Label applied to the node so a `Workspace` CR's `labelSelector` can match it |
| `KAITO_WORKSPACE_NAME` | `workspace-nemotron-3-nano-4b` | Name of the `Workspace` CR applied by `deploy-kaito-model.sh` |
| `KAITO_MODEL_PRESET` | `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` | KAITO preset name (= HF model ID) deployed by `deploy-kaito-model.sh` |
| `DYNAMO_NAMESPACE` | `dynamo` | Namespace for the Dynamo deployment |
| `DYNAMO_IMAGE` | `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0` | Container image running both `dynamo.frontend` and `dynamo.vllm` |
| `DYNAMO_MODEL_ID` | `Qwen/Qwen3-0.6B` | Small model used to prove the Dynamo path works |
| `HF_NAMESPACE` | `dynamo` | Namespace for the Hugging Face/TGI deployment |
| `HF_MODEL_ID` | `microsoft/Phi-3-mini-4k-instruct` | Model served by TGI |
| `HF_TOKEN` | *(empty)* | Only required for gated Hugging Face models |
| `TGI_IMAGE` | `ghcr.io/huggingface/text-generation-inference:latest` | TGI server image |
| `ENABLE_TAILSCALE` | `true` | Skips Tailscale install if set to `false` |
| `ENABLE_COCKPIT` | `true` | Skips Cockpit install if set to `false` |
| `AUTO_REBOOT` | `false` | If `true`, `01-install-nvidia-driver.sh` reboots automatically after driver install |

### Where do I put secrets like `HF_TOKEN`?

In `config.env`, never in `config.env.example`. `config.env` is listed in `.gitignore` so it never gets committed.

### What happens if I never create `config.env`?

Every script falls back to the defaults shown above via `${VAR:-default}` — the stack still deploys, just with default naming/models.
