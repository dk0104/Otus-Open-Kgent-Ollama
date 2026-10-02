# kind + kagent + local Ollama


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

# 4. (optional) open the web UI -> http://localhost:8082
make ui

# 5. tear down
make down
```

The model is configurable:

```bash
make up OLLAMA_MODEL=qwen3:4b
```

## Repository layout

```
├── Makefile                     # convenience targets
├── config/
│   ├── kind-cluster.yaml        # kind config (k8s 1.37 + v1beta1 API)
│   └── kagent-values.yaml       # kagent Helm values (ollama + substrate)
├── manifests/
│   ├── ollama/ollama.yaml       # Ollama Deployment + Service + PVC
│   └── kagent/
│       ├── harness.yaml         # Harness (native kagent runtime + WorkerPool)
│       └── agent-template.yaml  # the "k8s-expert" agent
├── scripts/
│   ├── lib.sh                   # versions, defaults, helpers
│   ├── prerequisites.sh         # toolchain check/install
│   ├── up.sh                    # end-to-end bring-up (idempotent)
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

See [`docs/TUTORIAL.md`](docs/TUTORIAL.md) for the full walkthrough and
explanations.

## References

- [kagent](https://kagent.dev/) · [kagent-dev/kagent](https://github.com/kagent-dev/kagent)
- [kagent 1.x — Install](https://kagent.dev/docs/kagent/1.x/setup/installation)
- [kagent 1.x — Your first agent](https://kagent.dev/docs/kagent/1.x/get-started/your-first-agent)
- [kagent 1.x — Ollama provider](https://kagent.dev/docs/kagent/1.x/setup/model-providers/ollama)
- [Agent Substrate](https://github.com/kagent-dev/substrate)
- [kind](https://kind.sigs.k8s.io/) · [Ollama](https://ollama.com/)
