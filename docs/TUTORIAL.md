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
- [6. Declare the Harness](#6-declare-the-harness)
- [7. Bring up the monitoring plane](#7-bring-up-the-monitoring-plane)
- [8. Deploy Google Online Boutique](#8-deploy-google-online-boutique)
- [9. Grafana ServiceAccount + API token](#9-grafana-serviceaccount--api-token)
- [10. Wire up the MCP servers](#10-wire-up-the-mcp-servers)
- [11. Declare the k8s-expert agent](#11-declare-the-k8s-expert-agent)
- [12. The monitoring dialogue](#12-the-monitoring-dialogue)
- [13. Chat with the agent](#13-chat-with-the-agent)
- [14. Clean up](#14-clean-up)
- [15. Going further](#15-going-further)

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

## 6. Declare the Harness

kagent models agents as two CRDs: a **`Harness`** (runtime + policy) and an
**`AgentTemplate`** (prompt + model + tools). The Harness is declared here; the
`k8s-expert` `AgentTemplate` is declared **last** (section 11), once its MCP
tool servers exist, so its tool bindings resolve on first admission.

```bash
kubectl apply -f manifests/kagent/harness.yaml
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

## 7. Bring up the monitoring plane

The monitoring plane lives in the `monitoring` namespace and is installed by
three Helm releases:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# Prometheus + Grafana + operator + node/kube-state exporters
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version 92.2.0 --namespace monitoring --create-namespace \
  -f config/kps-values.yaml

# blackbox-exporter (the prober the Boutique Probe resources call)
helm upgrade --install blackbox-exporter prometheus-community/blackbox-exporter \
  --version 11.20.0 --namespace monitoring \
  -f config/blackbox-values.yaml

# prometheus-mcp-server (PromQL + metric discovery exposed as MCP tools)
helm upgrade --install prometheus-mcp \
  oci://ghcr.io/pab1it0/prometheus-mcp-server/charts/prometheus-mcp-server \
  --version 1.1.1 --namespace monitoring \
  -f config/prom-mcp-values.yaml
```

Key points:

- **`kps-values.yaml`** sets a known Grafana admin (`admin`/`admin`) so the
  token bootstrap (section 9) works, and lets Prometheus auto-discover
  ServiceMonitors/Probes from **all** namespaces
  (`serviceMonitorNamespaceSelector: {}`, `probeNamespaceSelector: {}`), so the
  blackbox exporter and the Boutique probes are scraped regardless of who
  created them.
- **`blackbox-values.yaml`** defines two probe modules: `http_2xx` (the
  storefront) and `tcp_connect` (the gRPC backends + redis). A gRPC port does
  not answer an HTTP GET with 2xx, so `tcp_connect` is the correct module for
  the backends.
- **`prom-mcp-values.yaml`** points the MCP server at the in-cluster
  Prometheus (`http://kps-kube-prometheus-stack-prometheus.monitoring.svc:9090`)
  and serves Streamable HTTP on `prometheus-mcp:8080/mcp`.

`scripts/up.sh` waits for the operator, then Prometheus, Grafana,
blackbox-exporter, and prometheus-mcp to be ready.

## 8. Deploy Google Online Boutique

The target app is Google's [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)
— 12 microservices (frontend, carts, checkout, payments, ...) plus a
`loadgenerator` that generates traffic so the dashboards have data. The
upstream `release/kubernetes-manifests.yaml` (pinned to public images) is
vendored into the repo, and a `kustomization.yaml` injects the
`online-boutique` namespace:

```bash
kubectl apply -k manifests/boutique/
kubectl -n online-boutique rollout status deployment/frontend
```

Then the blackbox availability probes (two `Probe` resources) are applied so
Prometheus drives the blackbox-exporter against every endpoint:

```bash
kubectl apply -f manifests/monitoring/probes.yaml
```

- `boutique-frontend-http` (module `http_2xx`) → `frontend:80`.
- `boutique-backends-tcp` (module `tcp_connect`) → the 9 gRPC backends + redis.

Resulting metric: `probe_success{job="boutique-frontend-http", service="..."}`
(and `probe_duration_seconds`, ...). No Boutique source code is modified.

## 9. Grafana ServiceAccount + API token

The Grafana MCP server authenticates to Grafana with a ServiceAccount API
token. The kps chart ships a fixed admin user but no ServiceAccount, so
`scripts/grafana-token.sh` creates one (idempotently):

1. Port-forwards the Grafana service.
2. Ensures a ServiceAccount `kagent-mcp` (role `Editor`) exists (reused by name).
3. Resets it to exactly one token and stores it in the `grafana-mcp-token`
   Secret (namespace `kagent`) under the key `GRAFANA_SERVICE_ACCOUNT_TOKEN`.
4. Verifies the token against `GET /api/org`.

```bash
./scripts/grafana-token.sh
kubectl -n kagent get secret grafana-mcp-token
```

## 10. Wire up the MCP servers

Two MCP servers back the agent's monitoring tools:

- **Grafana MCP** — kagent's built-in `grafana-mcp` sub-chart. It is *deferred*
  during the initial kagent install (section 4, `--set grafana-mcp.enabled=false`)
  because its token Secret does not exist yet. Now that the token exists,
  re-upgrade kagent to enable it and restart the Pod so it picks up the current
  token:

  ```bash
  helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
    --version 1.0.0-alpha3 --namespace kagent --timeout 10m \
    --set providers.ollama.model="qwen3:8b" -f config/kagent-values.yaml
  kubectl -n kagent rollout restart deployment/kagent-grafana-mcp
  kubectl -n kagent rollout status deployment/kagent-grafana-mcp
  ```

  This creates the `RemoteMCPServer` **`kagent-grafana-mcp`**
  (`http://kagent-grafana-mcp.kagent:8000/mcp`) and a Deployment that talks to
  Grafana using `GRAFANA_URL` (`kps-grafana.monitoring.svc:80/api`) + the token.

- **Prometheus MCP** — a `RemoteMCPServer` that points at the
  prometheus-mcp server (section 7):

  ```bash
  kubectl apply -f manifests/monitoring/prometheus-mcp.yaml
  ```

  This creates the `RemoteMCPServer` **`prometheus-mcp`**
  (`http://prometheus-mcp.monitoring.svc:8080/mcp`).

Both must reach the `Accepted` condition (tools discovered) before the agent
can bind them:

```bash
kubectl -n kagent get remotemcpservers
# NAME                PROTOCOL         URL                                            ACCEPTED
# kagent-grafana-mcp  STREAMABLE_HTTP  http://kagent-grafana-mcp.kagent:8000/mcp     True
# prometheus-mcp      STREAMABLE_HTTP  http://prometheus-mcp.monitoring.svc:8080/mcp True
```

## 11. Declare the k8s-expert agent

Now that both MCP servers exist, the `AgentTemplate` is applied. It binds three
MCP tool servers and carries the monitoring system prompt:

```bash
kubectl apply -f manifests/kagent/agent-template.yaml
```

```yaml
spec:
  description: Kubernetes & DevOps expert powered by a local Ollama model
  modelConfig: { name: default-model-config }
  systemPrompt: |   # Kubernetes expert + monitoring workflow + dashboard JSON guide
    ...
  tools:
    - mcp: { server: { kind: RemoteMCPServer, name: kagent-tool-server } }  # kubectl/helm
    - mcp:                                                          # Prometheus
        server: { kind: RemoteMCPServer, name: prometheus-mcp }
        tools: [ execute_query, list_metrics, get_metric_metadata, get_targets ]
    - mcp:                                                          # Grafana
        server: { kind: RemoteMCPServer, name: kagent-grafana-mcp }
        tools: [ update_dashboard, patch_dashboard, search_dashboards,
                 get_dashboard_summary, create_folder, list_datasources ]
```

The `tools` list limits each server to the tools the agent needs (least
privilege). `up.sh` verifies the servers are `Accepted` before applying this,
and the AgentTemplate only becomes `Ready` once its bindings resolve:

```bash
kubectl -n kagent get agenttemplate k8s-expert -o \
  jsonpath='{.status.harnesses[0].conditions[?(@.type=="Ready")].status}'
# -> True
```

An empty `HARNESS` column with `READY=UNKNOWN` means the controller hasn't
reconciled the pair yet; `FALSE` means a stage failed — inspect
`status.harnesses[].conditions` (`Accepted`, `ResolvedRefs`, `Compatible`,
`Ready`) and the controller logs.

A reference dashboard (`templates/grafana/boutique-dashboard.example.json`)
ships in the repo as a structural guide (allowed panel types, namespace-scoped
PromQL) and as an importable example.

## 12. The monitoring dialogue

The heart of the demo. Open the web UI and drive the agent through a real
monitoring conversation:

```bash
./scripts/ui.sh    # -> http://localhost:8082
```

1. Start a conversation with `k8s-expert` and ask:
   > "What monitoring options can you build for the Online Boutique?"
2. The agent first discovers what is *really* scraped — `get_targets` and
   `list_metrics` — so it only proposes metrics that exist.
3. It proposes concrete scenarios grounded in real metrics, e.g.:
   - **Availability** — `probe_success{job="boutique-frontend-http"}`
   - **Request latency** — `probe_duration_seconds{job="boutique-frontend-http"}`
   - **Pod CPU** — `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="online-boutique"}[5m]))`
   - **Pod memory / restarts / readiness / replicas** — and so on.
4. Pick one or more. The agent resolves the Prometheus data source
   (`list_datasources`), ensures the `kagent-monitoring` folder
   (`create_folder`), and creates the dashboard (`update_dashboard`).
5. It returns a Grafana URL. Open Grafana
   (`kubectl -n monitoring port-forward svc/kps-grafana 3000:80` →
   http://localhost:3000, admin/admin) to see the panels with live data.
6. Ask for a change (e.g. "add a memory panel" or "widen the time range").
   The agent uses `get_dashboard_summary` + `patch_dashboard` to update the
   **same** dashboard in place — no duplicate.

Health-check the plane any time with `make verify-monitoring`.

## 13. Chat with the agent

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

## 14. Clean up

```bash
./scripts/down.sh      # asks for confirmation, then deletes the cluster
./scripts/down.sh --yes
```

Deleting the kind cluster removes Agent Substrate, kagent, the Ollama pod, the
model cache (PVC), and all agent state in one shot.

## 15. Going further

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
| kube-prometheus-stack | `92.2.0` |
| blackbox-exporter | `11.20.0` |
| prometheus-mcp-server | `1.1.1` |
| grafana-mcp | `0.1.12` (kagent sub-chart) |
| Google Online Boutique | `release/kubernetes-manifests.yaml` (vendored) |
