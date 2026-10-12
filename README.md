# kind + kagent + local Ollama

A fully local, reproducible demo: a Kubernetes-native AI agent
(`k8s-expert`, powered by an in-cluster Ollama model) that reasons about
Kubernetes **and builds Grafana dashboards for a real application** — Google
Online Boutique — from a conversation in the kagent web UI.

`make up` brings up the entire stack: a kind cluster, Agent Substrate, kagent,
Ollama, a Prometheus + Grafana + blackbox-exporter monitoring plane, and the
Boutique app itself. The monitoring plane is "invisible" in the presentation —
the agent discovers the real metrics and creates the dashboards for you.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | any recent | runs the kind node |
| kind | ≥ 0.32.0 | local cluster |
| kubectl | any | cluster access |
| Helm | 3.x | chart installs |
| jq, openssl | any | substrate identity bootstrap |
| kubectl-ate | v0.2.0-beta5 | Agent Substrate identity plugin |
| kagent CLI | latest | create/invoke agents |

> **Hardware:** Agent Substrate runs gVisor sandboxes plus a ~6 GB model in RAM.
> **16 GB RAM** (ideally 32 GB) and ~30 GB free disk are recommended.

Run `make prereqs` to verify everything and auto-install the two kagent-specific
tools (`kubectl-ate`, `kagent`) if missing.

## Quick start

```bash
# 1. check / install tooling
make prereqs

# 2. bring up the whole stack (first run downloads images + the model)
make up

# 3. talk to the agent
make chat Q="Why does my Pod stay in Pending state?"

# 4. the demo: open the web UI and ask the agent to build a dashboard
make ui    # -> http://localhost:8082
#    In the UI, ask "What monitoring options can you build for the Online
#    Boutique?" — pick a scenario and the agent creates a live Grafana
#    dashboard. See "Monitoring & dashboards" below.

# 5. health-check the monitoring plane (exit 0 = OK)
make verify-monitoring

# 6. tear down
make down
```

The model is configurable:

```bash
make up OLLAMA_MODEL=qwen3:4b
```

## Repository layout

```
├── Makefile                     # convenience targets (up, chat, ui, verify-monitoring, ...)
├── config/
│   ├── kind-cluster.yaml        # kind config (k8s 1.37 + v1beta1 API)
│   ├── kagent-values.yaml       # kagent Helm values (ollama + substrate + grafana-mcp)
│   ├── kps-values.yaml          # kube-prometheus-stack values (Prometheus + Grafana)
│   ├── blackbox-values.yaml     # blackbox-exporter values (+ http/tcp probe modules)
│   └── prom-mcp-values.yaml     # prometheus-mcp-server values (Prometheus MCP)
├── manifests/
│   ├── ollama/ollama.yaml       # Ollama Deployment + Service + PVC
│   ├── kagent/
│   │   ├── harness.yaml         # Harness (native kagent runtime + WorkerPool)
│   │   └── agent-template.yaml  # the "k8s-expert" agent (+ Prometheus/Grafana tools)
│   ├── monitoring/
│   │   ├── probes.yaml          # blackbox Probes for the Boutique (http + tcp)
│   │   └── prometheus-mcp.yaml  # RemoteMCPServer for the Prometheus MCP
│   └── boutique/
│       ├── kustomization.yaml   # injects the online-boutique namespace
│       └── online-boutique.yaml # Google Online Boutique (vendored, pinned)
├── templates/
│   └── grafana/
│       └── boutique-dashboard.example.json  # reference dashboard (structural guide)
├── scripts/
│   ├── lib.sh                   # versions, defaults, helpers
│   ├── prerequisites.sh         # toolchain check/install
│   ├── up.sh                    # end-to-end bring-up (idempotent, incl. monitoring)
│   ├── grafana-token.sh         # bootstrap Grafana ServiceAccount + API token
│   ├── verify-monitoring.sh     # post-up health gate for the monitoring plane
│   ├── chat.sh                  # chat with the agent
│   ├── ui.sh                    # port-forward the web UI
│   ├── status.sh                # inspect the stack
│   └── down.sh                  # delete the cluster
└── docs/
    └── TUTORIAL.md              # step-by-step deep dive
```

## Choosing a model

kagent agents **call tools**, so the model must support function/tool calling.
A model without tool support connects fine but fails as soon as it tries to use
a tool.

| Model | Size (Q4) | Tool calling | Notes |
|-------|-----------|--------------|-------|
| `qwen3:8b` | ~4.9 GB | ✅ strong | **default** — best balance of quality/size |
| `qwen3:4b` | ~2.4 GB | ✅ good | lighter machines |
| `qwen2.5:7b` | ~4.7 GB | ✅ good | older Qwen line |
| `llama3.2:3b` | ~2 GB | ⚠️ basic | smallest, weaker reasoning |

Change it with `OLLAMA_MODEL=...` (see `make up`).

## Monitoring & dashboards (the demo)

On top of the agent, `make up` brings up a monitoring plane and a target
application so the agent can build **real** dashboards:

| Piece | Namespace | What it is |
|-------|-----------|-----------|
| Prometheus + Grafana | `monitoring` | `kube-prometheus-stack` (release `kps`) — metrics + dashboards |
| blackbox-exporter | `monitoring` | Probes the Boutique endpoints (HTTP + TCP) |
| Prometheus MCP | `monitoring` | `prometheus-mcp-server` — PromQL + metric discovery as MCP tools |
| Google Online Boutique | `online-boutique` | The 12-microservice target app (traffic via `loadgenerator`) |
| Grafana MCP | `kagent` | kagent's built-in `grafana-mcp` — dashboard create/read/patch tools |

The agent (`k8s-expert`) is bound to three MCP tool servers: `kagent-tool-server`
(kubectl/helm), `prometheus-mcp` (query/discover metrics), and
`kagent-grafana-mcp` (create/read/patch dashboards).

### The dialogue (web UI)

1. `make ui` → open http://localhost:8082.
2. Start a conversation with `k8s-expert` and ask, e.g.:
   > "What monitoring options can you build for the Online Boutique?"
3. The agent checks what is *actually* scraped (`get_targets`, `list_metrics`)
   and proposes concrete scenarios grounded in real metrics (availability,
   latency, CPU, memory, restarts, readiness), each with a real PromQL.
4. Pick one or more. The agent builds a small dashboard in the
   `kagent-monitoring` folder and returns a Grafana URL.
5. Open the URL (below) to see the panels with live data.
6. Ask for a change — the agent updates the **same** dashboard in place
   (no duplicates).

### Open Grafana

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# -> http://localhost:3000  (admin / admin)
```

The dashboards the agent creates live in the `kagent-monitoring` folder.

### Verify the plane

```bash
make verify-monitoring    # exit 0 = Prometheus up, data source answers, MCPs accepted
```

## Troubleshooting

- **kind fails with `cannot obtain client without bootstrap ... connection refused`
  on a ZFS host** → the host's Docker data lives on ZFS, so the node's `/var`
  volume is `fstype=zfs` and the kubelet's cadvisor crashes with
  `failed to get rootfs info: cannot find filesystem info for device`.
  Build a node image that ships the `zfs` tooling and use it:

  ```bash
  ./scripts/build-node-image.sh
  KIND_NODE_IMAGE=kindest/node:v1.37.0-zfs make up
  ```

  (Check with `findmnt -no FSTYPE /` — if it says `zfs`, you're affected.
  Kubernetes ≤ 1.37 vendors a cadvisor with no fallback for this; the fix is
  upstream in cadvisor v0.60.6 and will land in a later Kubernetes minor.)
- **model pull fails with `x509: certificate is valid for <your-host>, not
  registry.ollama.ai`** → your host's DNS `search` domain (e.g. `keksel.pro`)
  is leaking into the cluster, and a wildcard record on that domain makes
  `registry.ollama.ai` resolve to the wrong IP. `config/kind-cluster.yaml`
  sets `networking.dnsSearch: []` to prevent this — recreate the cluster
  (`make down && make up`) if it was created before that change.
- **`kubectl ate --help` fails** → run `make prereqs`.
- **AgentInstance stays `UNKNOWN`/not ready** → `kubectl -n kagent get agenttemplate k8s-expert -o yaml`
  and check `status.harnesses[].conditions`.
- **Agent turns time out** → the WorkerPool is cold or undersized:
  `kubectl -n kagent get workerpools`; scale with
  `kubectl scale workerpool kagent-default -n kagent --replicas=2`.
- **Ollama out of memory** → lower `memory` limits in
  `manifests/ollama/ollama.yaml` and/or use a smaller model.
- **Model answers don't use tools / hallucinate** → the model lacks tool
  support; pick one from the table above.
- **Grafana panels are empty / "no data"** → the data source UID may not match.
  The agent resolves it via `list_datasources`; a reference dashboard ships at
  `templates/grafana/boutique-dashboard.example.json`. Run `make verify-monitoring`
  to confirm Prometheus is scraping.
- **`probe_success` missing in Grafana** → the blackbox `Probe`s need the prober
  reachable: check `kubectl -n monitoring get pods` (blackbox-exporter) and run
  `make verify-monitoring` (confirms both Boutique probe jobs are `up`).
- **Grafana MCP / Prometheus MCP not `Accepted`** →
  `kubectl -n kagent get remotemcpservers -o wide`, then check the underlying
  pods: `kubectl -n monitoring get pods` (prometheus-mcp) and
  `kubectl -n kagent get pods` (kagent-grafana-mcp).
- **Grafana login / token** → the demo uses `admin` / `admin` (set in
  `config/kps-values.yaml`). The agent's token is in the `grafana-mcp-token`
  Secret (namespace `kagent`), created by `scripts/grafana-token.sh`.

See [`docs/TUTORIAL.md`](docs/TUTORIAL.md) for the full walkthrough and
explanations.

## References

- [kagent](https://kagent.dev/) · [kagent-dev/kagent](https://github.com/kagent-dev/kagent)
- [kagent 1.x — Install](https://kagent.dev/docs/kagent/1.x/setup/installation)
- [kagent 1.x — Your first agent](https://kagent.dev/docs/kagent/1.x/get-started/your-first-agent)
- [kagent 1.x — Ollama provider](https://kagent.dev/docs/kagent/1.x/setup/model-providers/ollama)
- [Agent Substrate](https://github.com/kagent-dev/substrate)
- [kind](https://kind.sigs.k8s.io/) · [Ollama](https://ollama.com/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [blackbox-exporter](https://github.com/prometheus-community/helm-charts/tree/main/charts/blackbox-exporter)
- [prometheus-mcp-server](https://github.com/pab1it0/prometheus-mcp-server)
- [Google Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)
