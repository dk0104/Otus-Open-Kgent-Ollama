# Tutorial: kind + kagent + local Ollama

This walkthrough explains *what* every step does and *why*, so you can adapt it
beyond the happy path. The `scripts/up.sh` script automates all of it; this
document is the manual, explained version.

- [0. The pieces and why they fit](#0-the-pieces-and-why-they-fit)
- [1. Prerequisites](#1-prerequisites)
- [2. Create the kind cluster](#2-create-the-kind-cluster)
- [3. Install Agent Substrate](#3-install-agent-substrate)
- [4. Install kagent](#4-install-kagent)
- [5. Run Ollama in the cluster](#5-run-ollama-in-the-cluster)
- [6. Declare the agent](#6-declare-the-agent)
- [7. Chat with the agent](#7-chat-with-the-agent)
- [8. Clean up](#8-clean-up)
- [9. Going further](#9-going-further)

## 0. The pieces and why they fit

| Piece | Role |
|-------|------|
| **kind** | Runs a real Kubernetes cluster in Docker on your laptop. |
| **Agent Substrate** | kagent's execution engine: spins up gVisor-sandboxed "Actors" (one per running agent turn), suspends them between turns, and writes snapshots to object storage. |
| **kagent** | A Kubernetes-native framework (CNCF Sandbox) that turns agents into CRDs: `Harness` (runtime + policy), `AgentTemplate` (prompt + model + tools), `AgentInstance` (one running conversation). |
| **Ollama** | Serves a local LLM inside the cluster. No cloud, no API key. |

The flow: you ask the `k8s-expert` agent a question → the kagent controller
finds a Worker → an Actor boots the model config and system prompt → the
runtime calls Ollama → the reply streams back over A2A (Agent-to-Agent
protocol).

> **Important:** kagent agents execute inside sandboxed Actors with controlled
> egress. They can reach in-cluster Service DNS, but an Ollama server on your
> laptop is *not* reachable from inside an Actor — even if `kubectl
> port-forward` makes it reachable from your terminal. That is why we run
> Ollama as a workload in the cluster rather than pointing at `localhost`.

## 1. Prerequisites

```bash
make prereqs
```

This checks `docker`, `kind`, `kubectl`, `helm`, `jq`, `openssl`, `ollama`, and
installs the two kagent-specific tools if missing:

- **kubectl-ate** — the Agent Substrate kubectl plugin, used to bootstrap mTLS
  CA pools. It must match the substrate version (`0.2.0-beta5`).
- **kagent** — the CLI used to create AgentInstances and chat with them.

## 2. Create the kind cluster

```bash
sed 's/__CLUSTER_NAME__/kagent/' config/kind-cluster.yaml \
  | kind create cluster --image kindest/node:v1.37.0 --config=-
```

> **ZFS hosts** (e.g. a ZFS root — check with `findmnt -no FSTYPE /`): the node's
> `/var` volume ends up `fstype=zfs`, which crashes the kubelet with
> `cannot find filesystem info for device`. Use the ZFS-patched image instead:
>
> ```bash
> ./scripts/build-node-image.sh
> KIND_NODE_IMAGE=kindest/node:v1.37.0-zfs make up
> ```

Two details matter here:

- **Kubernetes ≥ 1.37** — required by Agent Substrate.
- **`certificates.k8s.io/v1beta1`** — Agent Substrate depends on this API group,
  enabled via `runtimeConfig` in the kind config.

## 3. Install Agent Substrate

Agent Substrate runs in the `ate-system` namespace.

```bash
# CRDs first
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.2.0-beta5 --namespace ate-system --create-namespace

# control plane + data plane (no --wait: pods can't be ready until identity exists)
helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.2.0-beta5 --namespace ate-system
```

### Identity bootstrap (the part everyone trips on)

Agent Substrate authenticates its components with mutual TLS, and the identity
material is **not** created by any Helm chart — you create it with `kubectl-ate`:

```bash
# CA pools for service DNS and pod identity certs
kubectl ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool \
  --secret-namespace=podcertificate-controller-system
kubectl ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool \
  --secret-namespace=podcertificate-controller-system

# actor identity: a JWT pool + a CA pool
kubectl ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool \
  --secret-namespace=ate-system
kubectl ate admin make-ca-pool --ca-id=1 --name=actor-id-ca-pool \
  --secret-namespace=ate-system

# extract the actor identity root cert into a secret the API server reads
actor_id_ca_root="$(kubectl get secret actor-id-ca-pool -n ate-system \
  -o jsonpath='{.data.pool}' | base64 --decode \
  | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem)"
kubectl create secret generic actor-id-ca-certs -n ate-system \
  --from-literal=ca.crt="${actor_id_ca_root}" --dry-run=client -o yaml | kubectl apply -f -

# authentication: accept Kubernetes ServiceAccount tokens for the API audience
k8s_issuer="$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)"
kubectl create configmap ate-api-authentication -n ate-system \
  --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${k8s_issuer}
  audiences: [api.ate-system.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
" --dry-run=client -o yaml | kubectl apply -f -

# roll out again so pods mount the identity material, then wait
helm upgrade substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.2.0-beta5 --namespace ate-system --reuse-values --wait --timeout 10m
```

> The issuer is read from the cluster's own OIDC discovery document instead of
> being hardcoded: kind 1.37 advertises `https://kubernetes.default.svc.cluster.local`,
> and a mismatch only surfaces later as `token issuer ... not trusted`.

Verify with `kubectl get pods -n ate-system` — expect `ate-api-server`,
`ate-controller`, `atelet`, `atenet-router`, `rustfs`, and `postgres` pods.

`rustfs` is an in-cluster S3-compatible store that Agent Substrate uses for
Actor snapshots in a development install (bucket `ate-snapshots`, default
credentials `rustfsadmin`/`rustfsadmin`).

## 4. Install kagent

```bash
helm upgrade --install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 1.0.0-alpha3 --namespace kagent --create-namespace --wait

helm upgrade --install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 1.0.0-alpha3 --namespace kagent --create-namespace --timeout 10m \
  --set providers.ollama.model="qwen3:8b" \
  -f config/kagent-values.yaml
```

The values file wires up three things:

```yaml
providers:
  default: ollama
  ollama:
    config:
      host: http://ollama.ollama.svc.cluster.local:11434
      options:
        num_ctx: "32768"

controller:
  substrate:
    enabled: true
    ateApiEndpoint: dns:///api.ate-system.svc:443
    atenetRouterURL: http://atenet-router.ate-system.svc:80
    defaultWorkerPool:
      name: kagent-default

substrateWorkerPool:
  create: true
  replicas: 1
  workerImage: "ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.2.0-beta5"
```

- `providers.ollama` makes the chart generate a `ModelConfig` named
  **`default-model-config`** pointing at the in-cluster Ollama Service.
  `num_ctx` is the context window the model will serve.
- `controller.substrate` connects the kagent controller to Agent Substrate.
- `substrateWorkerPool` provisions one gVisor Worker that agent turns run on.
  No Harness can run until a WorkerPool exists.

Verify:

```bash
kubectl rollout status deployment/kagent-controller -n kagent
kubectl get workerpools -n kagent        # kagent-default  READY 1/1
```

## 5. Run Ollama in the cluster

```bash
kubectl apply -f manifests/ollama/ollama.yaml
kubectl -n ollama rollout status deployment/ollama

# pull the model into the pod's PVC-backed model cache
kubectl -n ollama exec deploy/ollama -- ollama pull qwen3:8b
kubectl -n ollama exec deploy/ollama -- ollama list
```

The manifest creates a `Namespace`, a `Deployment` (with
`OLLAMA_HOST=0.0.0.0` and a TCP readiness probe), a `Service` on port 11434,
and a `PersistentVolumeClaim` mounted at `/root/.ollama` so the model survives
pod restarts.

### Choosing a model

The model **must support function/tool calling**, because kagent agents call
tools. Recommended options:

| Model | Pull command | Notes |
|-------|--------------|-------|
| `qwen3:8b` | `ollama pull qwen3:8b` | default, strong tool calling |
| `qwen3:4b` | `ollama pull qwen3:4b` | lighter |
| `qwen2.5:7b` | `ollama pull qwen2.5:7b` | good, older line |
| `llama3.2:3b` | `ollama pull llama3.2:3b` | smallest, basic tools |

Change the model in both places: `make up OLLAMA_MODEL=...` and the
`--set providers.ollama.model=...` value.

## 6. Declare the agent

kagent models agents as two CRDs:

```bash
kubectl apply -f manifests/kagent/harness.yaml
kubectl apply -f manifests/kagent/agent-template.yaml
```

**`Harness`** — a reusable runtime + policy. It *admits* `AgentTemplate`s whose
labels match its selector, and declares where turns run:

```yaml
spec:
  kagent: {}                     # kagent's native runtime adapter
  workload:
    image: ghcr.io/kagent-dev/kagent/golang-adk@sha256:c8ab...  # pinned by digest
  substrate:
    workerPoolRef: { name: kagent-default }
    snapshotPolicy:
      location: s3://ate-snapshots/kagent/   # in-cluster rustfs bucket
  allowedAgentTemplates:
    selector: { matchLabels: { kagent.dev/harness: kagent } }
```

**`AgentTemplate`** — portable agent behavior (prompt + model reference):

```yaml
spec:
  description: Kubernetes & DevOps expert powered by a local Ollama model
  modelConfig: { name: default-model-config }
  systemPrompt: |
    You are a senior platform/DevOps engineer and Kubernetes expert. ...
```

Confirm the pair compiled:

```bash
kubectl -n kagent get agenttemplate k8s-expert -o jsonpath='{.status.harnesses[0].conditions[?(@.type=="Ready")].status}'
# -> True
```

An empty `HARNESS` column with `READY=UNKNOWN` means the controller hasn't
reconciled the pair yet. `FALSE` means a stage failed — inspect
`status.harnesses[].conditions` (`Accepted`, `ResolvedRefs`, `Compatible`,
`Ready`) and the controller logs.

## 7. Chat with the agent

```bash
./scripts/chat.sh "Why does my Pod stay in Pending?"
```

Under the hood:

```bash
kagent create agent-instance --harness kagent --agent-template k8s-expert
kagent invoke --agent-instance <id> --task "Why does my Pod stay in Pending?"
```

- **`AgentInstance`** is one running conversation. Creating it starts an Actor
  on the WorkerPool. The CLI returns once it reaches `READY`.
- **`invoke`** sends the task over A2A; `--stream` streams the reply as it is
  produced. The CLI auto-port-forwards to the `kagent-controller` Service
  (port 8083) when nothing is listening locally.

For the web UI:

```bash
./scripts/ui.sh    # -> http://localhost:8082
```

## 8. Clean up

```bash
./scripts/down.sh      # asks for confirmation, then deletes the cluster
./scripts/down.sh --yes
```

Deleting the kind cluster removes Agent Substrate, kagent, the Ollama pod, the
model cache (PVC), and all agent state in one shot.

## 9. Going further

- **Give the agent real cluster tools.** The kagent chart ships a built-in MCP
  tool server (Kubernetes, Helm, Argo, Prometheus, Grafana, Cilium tools). Bind
  it to the agent by adding a `tools` block to the `AgentTemplate`:

  ```yaml
  tools:
    - mcp:
        server:
          kind: RemoteMCPServer
          name: kagent-tool-server
  ```

- **Multiple models / providers.** Add more `ModelConfig` CRs (e.g. a second
  Ollama model, or an OpenAI provider behind a `Secret`) and reference them
  from different `AgentTemplate`s.

- **Scale the WorkerPool.** Workers host at most one Actor at a time and are
  released between turns. Scale with
  `kubectl scale workerpool kagent-default -n kagent --replicas=3`.

- **Observability.** kagent supports OpenTelemetry tracing; see the
  [tracing guide](https://kagent.dev/docs/kagent/1.x/observability/tracing).

## Reference versions

| Component | Version |
|-----------|---------|
| kind node image | `kindest/node:v1.37.0` |
| kagent | `1.0.0-alpha3` |
| Agent Substrate | `0.2.0-beta5` |
| kagent runtime image | `ghcr.io/kagent-dev/kagent/golang-adk@sha256:699c7a36daa0050d5954f42ad3b614690d825664cf64ffe8871dbe20dc68464e` |
| Ollama model | `qwen3:8b` (configurable) |
