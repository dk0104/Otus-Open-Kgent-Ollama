# k8s-expert Monitoring & Dashboard Assistant Design

Spec: `k8s-expert-monitoring`  
Status: design-approved  
Created: 2026-10-11  
Brainstorm: `./brainstorm.md`  
Requirements: `./requirements.md`

## Summary

We extend the existing kind + kagent + Ollama stack with a **Prometheus/Grafana monitoring plane** and
give the `k8s-expert` agent **MCP tools** to (a) query/discover real Prometheus metrics and (b) create and
update Grafana dashboards. The whole plane is brought up automatically by `make up` (invisible in the
presentation) and the target app is the **Google Online Boutique**, monitored purely as a Kubernetes
workload (no app instrumentation). The user drives everything through a natural-language conversation in
the **kagent Web UI** (port 8082): ask for monitoring options for the app → the agent grounds a list of
scenarios in real metrics → the user selects → the agent creates a Grafana dashboard → the user reviews
and, if needed, the agent refines the same dashboard in place.

The agent's new capabilities are delivered as two **MCP servers** attached to the AgentTemplate through
`RemoteMCPServer` resources: the kagent chart's built-in **Grafana MCP** (`grafana/mcp-grafana`) for
dashboard operations, and **`pab1it0/prometheus-mcp-server`** for PromQL queries and metric discovery. This
reuses kagent's existing tool-binding mechanism (the same one already used for the `kagent-tool-server`
kubectl tools) and adds no custom agent runtime code.

## Goals and Non-Goals

### Goals

- One-command bring-up of the monitoring plane + target app inside `make up` (FR-001, FR-002, NFR-002).
- Real, scrapable metrics for the Boutique as a workload: kube-state-metrics, node-exporter, cadvisor,
  blackbox availability (FR-003).
- Agent tools for Prometheus query/discovery (FR-006, FR-007) and Grafana dashboard create/read/update
  (FR-008, FR-009, FR-010).
- A Web UI conversation that lists scenarios, creates a working dashboard, and refines it in place
  (FR-012 … FR-017).
- Reproducible, participant-readable code and docs (FR-018, NFR-003).

### Non-Goals

- Presentation/slides (separate session).
- Application-level / business metrics via instrumenting Boutique services (no app code changes).
- Alerting rules as a core feature (the Grafana MCP exposes alerting tools, but we do **not** bind them).
- Production HA, multi-cluster, long-term retention, CLI as the primary interface.

## Architecture

### Components (added to the existing stack)

| Component | Where | Provided by | Purpose |
| --- | --- | --- | --- |
| Prometheus (via prometheus-operator) | `monitoring` | `kube-prometheus-stack` chart | Metric store + scraping |
| Grafana | `monitoring` | `kube-prometheus-stack` chart | Dashboards + UI (port-forward) |
| kube-state-metrics, node-exporter, cadvisor (kubelet) | `monitoring` / cluster | `kube-prometheus-stack` default ServiceMonitors | Workload + node metrics |
| Alertmanager | `monitoring` | `kube-prometheus-stack` chart | Present for completeness (not a core feature) |
| blackbox-exporter | `monitoring` | separate `prometheus-community/blackbox-exporter` chart | HTTP availability probes of Boutique services |
| `Probe` resources | `monitoring` | our manifests | Boutique availability: `http_2xx` on the frontend (HTTP) + `tcp_connect` on the gRPC backends/redis |
| Online Boutique | `online-boutique` | vendored upstream `kubernetes-manifests` | Target application |
| Grafana ServiceAccount + token | `monitoring` → Secret in `kagent` | `up.sh` (Grafana Admin API) | Programmatic dashboard access |
| Grafana MCP server | `kagent` | kagent chart sub-chart `grafana-mcp` | Dashboard create/read/patch tools |
| Prometheus MCP server | `monitoring` | `pab1it0/prometheus-mcp-server` chart | PromQL query + discovery tools |
| `RemoteMCPServer` ×2 | `kagent` | our manifests | Bind the two MCP servers to the AgentTemplate |
| `k8s-expert` AgentTemplate (updated) | `kagent` | our manifest | New tool bindings + monitoring system prompt |

### Why two MCP servers (and not just Grafana MCP)

The Grafana MCP server can also query Prometheus through its data source. We still add a dedicated
Prometheus MCP server because: (1) it keeps **Prometheus concerns** (query, `list_metrics`,
`get_targets`, `get_metric_metadata`) cleanly separated from **Grafana concerns** (dashboards), which maps
directly to FR-006/007 vs FR-008–010 and is clearer for participants; (2) discovery tools (`get_targets`,
`list_metrics`) are more directly useful for scenario generation than the Grafana data-source metadata
tools. See Risks (context budget) for the trade-off.

### Data flow (the conversation)

```mermaid
flowchart TD
  U[User in kagent Web UI :8082] -->|1. 'list monitoring options for Online Boutique'| A[k8s-expert agent]
  A -->|k8s_get_resources| K8s[(Cluster)]
  A -->|list_metrics / get_targets / get_metric_metadata| PMCP[Prometheus MCP]
  PMCP --> P[(Prometheus)]
  A -->|2. list concrete scenarios| U
  U -->|3. select scenarios| A
  A -->|4. update_dashboard (create, JSON)| GMCP[Grafana MCP]
  GMCP --> G[(Grafana)]
  A -->|5. dashboard URL| U
  U -->|6. review in browser; request change| A
  A -->|get_dashboard_summary / patch_dashboard (in place)| GMCP
  G -->|port-forward :3000| B[User browser]
```

1. **Identify:** agent uses `k8s_get_resources` to confirm the Boutique workloads exist
   (namespace `online-boutique`). If missing → prompt to run `make up` (Edge case).
2. **Discover:** agent uses `get_targets` + `list_metrics` + `get_metric_metadata` (filtered to the
   namespace) to see what is actually scrapeable.
3. **Propose:** agent maps available metric families to concrete scenarios (availability, CPU, memory,
   restarts, request latency) and lists them.
4. **Create:** agent composes a compact Grafana dashboard JSON (template-guided, restricted panel types,
   real PromQL) and calls `create_folder` (once) + `update_dashboard`.
5. **Surface:** agent resolves the dashboard uid (`search_dashboards`) and returns a Grafana URL based on
   the port-forwarded Grafana address.
6. **Refine:** on user feedback, agent uses `get_dashboard_summary` then `patch_dashboard` to update the
   same dashboard in place (FR-015) — no duplicate.

## Data Model

### Kubernetes resources we add

- **`RemoteMCPServer`** (`api.kagent.dev/v1alpha3`) ×2 in `kagent`:
  - `grafana-mcp` → `url: http://<grafana-mcp-svc>.kagent.svc:<port>/mcp`, `protocol: STREAMABLE_HTTP`
    (created by the kagent chart when `grafana-mcp.enabled: true` — **verify name/url on alpha3**).
  - `prometheus-mcp` → `url: http://prometheus-mcp.monitoring.svc:<port>/mcp`, `protocol: STREAMABLE_HTTP`.
- **`Secret` `grafana-mcp-token`** in `kagent`: holds the Grafana ServiceAccount API token
  (`GRAFANA_SERVICE_ACCOUNT_TOKEN`), referenced by the `grafana-mcp` sub-chart.
- **`Probe`** resources (Prometheus operator) in `monitoring`, driven by the blackbox-exporter. Two
  probes, chosen per protocol (see `manifests/monitoring/probes.yaml`):
  - `boutique-frontend-http` → module `http_2xx`, target `frontend.online-boutique.svc:80` (the storefront
    HTTP endpoint — the app's real HTTP interface).
  - `boutique-backends-tcp` → module `tcp_connect`, targets the 9 gRPC backends + `redis-cart:6379`. A gRPC
    port does not answer a plain HTTP GET with 2xx, so `tcp_connect` is the correct module for the backends.
  - The `tcp_connect` module is added to the blackbox config in `config/blackbox-values.yaml` (the chart
    default only ships `http_2xx`).
- **Vendored Boutique manifests** under `manifests/boutique/`, applied into `online-boutique`.
  - Source: the upstream **`/release/kubernetes-manifests.yaml`** (not the raw `kubernetes-manifests/`
    directory). Upstream documents that the raw directory is *not* directly deployable (it relies on
    skaffold to fill in `image:` tags), whereas `/release` ships **pre-built, publicly pullable images**
    pinned to `v0.10.7` (`us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/<svc>:v0.10.7`).
    We vendor that single file as `online-boutique.yaml` and add a `kustomization.yaml` that injects
    `namespace: online-boutique`. `loadgenerator` is included (it is present in the release manifest) so
    the app generates traffic for the dashboards. No Boutique source code is modified (Option A).

### Grafana dashboard JSON (what the agent generates)

- A dashboard object with a bounded set of panels; each panel: `type` ∈ {`timeseries`, `stat`, `gauge`,
  `table`}, `title`, `datasource` (resolved Prometheus data source), `targets[].expr` (PromQL),
  `gridPos`, minimal `fieldConfig`.
- **Data source UID** is resolved at runtime via `list_datasources` (the kube-prometheus-stack Prometheus
  data source; commonly UID `PBFA97CFB590B2093`, but we do not hard-code it).
- **Controlled location (NFR-005):** dashboards live in a dedicated folder (e.g., `kagent-monitoring`)
  created via `create_folder`; naming convention `<app>-<scenario-set>` enables in-place updates.
- A **reference template** (`templates/grafana/boutique-dashboard.example.json`) ships in the repo as an
  example for participants and as the structural guide embedded in the system prompt.

### Scenario → PromQL (examples)

| Scenario | Panel type | PromQL (namespace-scoped) |
| --- | --- | --- |
| Availability (HTTP) | stat / timeseries | `probe_success{job="boutique-blackbox"}` |
| Request latency | timeseries | `probe_duration_seconds{job="boutique-blackbox"}` |
| Pod CPU | timeseries | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="online-boutique"}[5m]))` |
| Pod memory | timeseries / gauge | `sum by (pod) (container_memory_working_set_bytes{namespace="online-boutique"})` |
| Restarts | stat / table | `kube_pod_container_status_restarts_total{namespace="online-boutique"}` |
| Pod readiness | table / stat | `sum by (pod) (kube_pod_container_status_ready{namespace="online-boutique"})` |
| Replica availability | stat | `kube_deployment_status_replicas_available{namespace="online-boutique"}` |

The exact label set (`pod`, `container`, service labels) is confirmed at bring-up from `get_targets` /
`list_metrics` (the Boutique pods carry an `app`/`app.kubernetes.io/name` label used to scope queries).

## API / Interface Changes

### `make up` (scripts/up.sh) — new steps, in order

1. Deploy **monitoring plane**: `helm upgrade --install kps oci://prometheus-community/kube-prometheus-stack`
   (namespace `monitoring`, values in `config/monitoring-values.yaml`).
2. Deploy **blackbox-exporter** chart + apply `Probe` manifests.
3. Deploy **Online Boutique**: `kubectl apply -f manifests/boutique/` (namespace `online-boutique`).
4. Create **Grafana ServiceAccount** (role `Editor`) + API token via the Grafana Admin API (using the
   chart's admin credentials), store the token in `Secret grafana-mcp-token`.
5. (Re)install **kagent** with `grafana-mcp.enabled: true` + `grafana.url`/token (existing step, new values).
6. Deploy **Prometheus MCP server** chart (namespace `monitoring`) + apply `RemoteMCPServer prometheus-mcp`
   (in `kagent`).
7. Apply **updated AgentTemplate** `k8s-expert` (new MCP bindings + system prompt).

All steps remain idempotent (`helm upgrade --install`, guarded `kubectl apply`/`create`) to satisfy
NFR-002.

### Agent tool bindings (AgentTemplate `spec.tools`)

Add two MCP bindings (keep the existing `kagent-tool-server` binding, trimmed to what the flow needs):

- `prometheus-mcp`: `execute_query`, `list_metrics`, `get_metric_metadata`, `get_targets`
  (`execute_range_query` optional).
- `grafana-mcp`: `update_dashboard`, `patch_dashboard`, `search_dashboards`, `get_dashboard_summary`,
  `create_folder`, `list_datasources`.
- `kagent-tool-server`: keep `k8s_get_resources` (and existing kubectl tools the agent already uses).

### System prompt (additions)

- The agent now has **Prometheus** and **Grafana** tools in addition to kubectl tools.
- Workflow guidance: identify the app → discover real metrics → propose scenarios grounded in what is
  actually scrapeable → on selection, build a **small** dashboard (few panels, allowed types) with real
  PromQL → return the Grafana URL → on feedback, **patch the existing dashboard** (never duplicate).
- Dashboard JSON structural guide (the template skeleton) + rule: resolve the data source via
  `list_datasources`; keep panels minimal to bound JSON size.
- If a metric/app is not found, say so (no fabricated metrics, NFR-004).

### New/changed files

- `config/monitoring-values.yaml` (new): kube-prometheus-stack + blackbox + prometheus-mcp values.
- `config/kagent-values.yaml` (changed): `grafana-mcp.enabled: true`, `grafana.url`, token reference.
- `scripts/lib.sh` (changed): chart versions + `monitoring`/`online-boutique` namespace pins.
- `scripts/up.sh` (changed): new steps above; `scripts/status.sh` (changed): monitoring status block.
- `manifests/monitoring/` (new): `RemoteMCPServer prometheus-mcp`, `probes.yaml`, Grafana SA bootstrap
  notes; `manifests/boutique/` (new): vendored upstream manifests.
- `templates/grafana/boutique-dashboard.example.json` (new): reference dashboard.
- `Makefile` (optional): convenience target(s); `make up` stays the single entry point.
- `README.md` + `docs/TUTORIAL.md` (changed): monitoring section + demo dialogue walkthrough.

## Error Handling

| Failure | Detection | Behavior |
| --- | --- | --- |
| Grafana not ready | `up.sh` waits for rollout; MCP `list_datasources` errors | Agent reports "Grafana not reachable"; `up.sh` retries |
| No metrics yet (fresh scrape) | `get_targets` empty / `execute_query` no series | Agent reports "no data yet, wait for first scrape" (NFR-004) |
| Invalid dashboard JSON | Grafana API 400 from `update_dashboard` | Agent sees the error, retries with corrected JSON (bounded), then reports |
| Misspelled bound tool | kagent compiles but tool never called | Bring-up task reads `RemoteMCPServer.status.discoveredTools` and checks spellings |
| Boutique not deployed | `k8s_get_resources` empty for `online-boutique` | Agent prompts to run `make up` (Edge case) |
| Grafana auth failure | MCP 401 | Clear, actionable error; check `grafana-mcp-token` Secret |
| Model lacks tool calling | agent ignores tools | Documented known limitation (NFR-006) |

Retries are bounded (no infinite loops). All errors are surfaced to the user in the conversation; nothing
corrupts existing dashboards on a failed write.

## Security and Privacy

- **Grafana token:** dedicated ServiceAccount with role `Editor` (dashboards create/read/write, folders
  read/create) — least privilege for the task. Token stored only in a Kubernetes `Secret`
  (`grafana-mcp-token`), referenced by the `grafana-mcp` sub-chart. No token in repo files.
- **Prometheus:** in-cluster, no auth by default in kube-prometheus-stack; the Prometheus MCP reaches it
  in-cluster only. No external exposure.
- **No external exposure:** Grafana and Prometheus are reachable only via `kubectl port-forward`; no
  LoadBalancer/Ingress is created.
- **RBAC:** the existing `kagent-tool-server` already runs with cluster-admin for kubectl tools; the new
  MCP servers use their own service accounts scoped to Grafana/Prometheus. No broad new cluster RBAC.
- **Local only:** everything runs in a local kind cluster; no data leaves the machine.

## Testing Strategy

- **Unit tests:** limited — the change is mostly manifests, values, prompts, and bash. Cover any new bash
  helper functions (e.g., token bootstrap, idempotency guards) if factored.
- **Integration (scripted):** extend `scripts/status.sh` (or add `scripts/verify-monitoring.sh`) to assert:
  Prometheus targets are `up` for the expected jobs; the Grafana Prometheus data source answers a sample
  PromQL query; a `kagent-monitoring` folder/dashboards can be listed; `kubectl get remotemcpserver -n kagent`
  shows both servers `ACCEPTED=True` with the expected tools in `status.discoveredTools`.
- **End-to-end / manual (primary for a demo):**
  1. `make up` → monitoring plane + Boutique ready; Prometheus scraping; Grafana reachable with a working
     Prometheus data source.
  2. Web UI: ask for monitoring options for the Boutique → agent lists concrete, real-metric scenarios.
  3. Select scenarios → agent creates a dashboard whose panels render **real data** in the browser.
  4. Request a change → agent updates the **same** dashboard in place (no duplicate).
  5. Re-run `make up` to confirm idempotency (NFR-002).
- **Regression coverage:** the idempotency re-run + the scripted integration checks double as regression
  gates; the reference dashboard template is a stable artifact to diff against.

## Rollout and Migration

- **Bring-up order** is enforced in `up.sh`: monitoring plane + Boutique first (so metrics exist), then
  Grafana SA/token, then kagent (with `grafana-mcp` on) + Prometheus MCP + `RemoteMCPServer`s, then the
  updated AgentTemplate last (it references the servers).
- **Version-pinning risk:** the repo pins kagent `1.0.0-alpha3`. The `grafana-mcp` sub-chart behavior
  (auto `RemoteMCPServer` name/url, exact tool names) was read from kagent `main`. **A bring-up
  verification task must inspect the alpha3 reality** (`kubectl get remotemcpserver -n kagent`, read
  `status.discoveredTools`) and adjust the AgentTemplate bindings before the dialogue is validated.
- **Rollback:** `make down` deletes the whole cluster (existing, simplest). For partial rollback,
  `helm uninstall` the added releases (`kps`, `blackbox-exporter`, `prometheus-mcp`) and delete the added
  `RemoteMCPServer`s and the updated AgentTemplate (re-apply the previous one).
- **No data migration:** the monitoring plane is new; nothing existing is reshaped. The existing Ollama /
  substrate / kagent steps are untouched except the `grafana-mcp` value.

## Requirements Traceability

| Requirement | Design Decision | Validation |
| ----------- | --------------- | ---------- |
| FR-001 | `make up` step 1 deploys `kube-prometheus-stack` (+blackbox step 2) into `monitoring` | `verify-monitoring`: Prometheus + Grafana pods ready, targets `up` |
| FR-002 | `make up` step 3 applies vendored Boutique manifests into `online-boutique` | `kubectl get deploy -n online-boutique` all available |
| FR-003 | kube-state-metrics/node-exporter/cadvisor via chart defaults + blackbox `Probe`s for Boutique | Prometheus targets `up`; sample namespace-scoped queries return series |
| FR-004 | Grafana preconfigured Prometheus data source (chart) + port-forward | Grafana Explore runs a query against the data source |
| FR-005 | Grafana SA (Editor) + token in `Secret grafana-mcp-token`; referenced by `grafana-mcp` | MCP `list_datasources`/`update_dashboard` succeed (no 401) |
| FR-006 | `prometheus-mcp` `execute_query` bound to agent | Agent answers a "what is CPU for X" via a real query |
| FR-007 | `prometheus-mcp` `list_metrics`/`get_metric_metadata`/`get_targets` bound | Agent lists real metrics/targets for the namespace |
| FR-008 | `grafana-mcp` `update_dashboard` (create) bound | A new dashboard appears in the chosen folder |
| FR-009 | `grafana-mcp` `search_dashboards`/`get_dashboard_summary` bound | Agent retrieves an existing dashboard by name/uid |
| FR-010 | `grafana-mcp` `patch_dashboard` bound | Agent updates the same dashboard in place |
| FR-011 | existing `kagent-tool-server` `k8s_get_resources` (kept) | Agent maps "Online Boutique" → `online-boutique` workloads |
| FR-012 | system-prompt workflow + FR-006/007 tools | E2E: agent lists concrete, real-metric scenarios |
| FR-013 | system-prompt workflow + FR-008 (template-guided JSON) | E2E: selecting scenarios creates a working dashboard |
| FR-014 | agent returns Grafana URL from `search_dashboards` uid + port-forward base | E2E: user can open the returned URL |
| FR-015 | `patch_dashboard` in-place update; folder + naming convention | E2E: a change updates the same dashboard (no duplicate) |
| FR-016 | template skeleton + restricted panel types in prompt; Grafana API validation + bounded retry | E2E: generated dashboards render; invalid JSON is rejected/retried |
| FR-017 | Scenario→PromQL mapping table; data source resolved via `list_datasources` | E2E: panels show real data for the selected scenarios |
| FR-018 | README/TUTORIAL monitoring section + demo walkthrough | A participant reproduces the flow from docs alone |
| NFR-001 | values set modest resource limits; documented 16 GB+ constraint | `make up` succeeds on the reference hardware; no OOM on the node |
| NFR-002 | all steps idempotent (`helm upgrade --install`, guarded apply) | re-run `make up` twice; no duplicates/errors |
| NFR-003 | clear file layout, comments in scripts, reference template, docs | review: new files are self-explanatory for participants |
| NFR-004 | agent grounded in `get_targets`/`list_metrics`; "say so if not found" rule | E2E: with a missing app/metric, agent reports absence, not fake data |
| NFR-005 | dedicated `kagent-monitoring` folder + naming convention | E2E: dashboards land in the folder; updates reuse the uid |
| NFR-006 | relies on tool calling; documented model requirement | uses a tool-calling model (qwen3:8b default) |

## Risks and Trade-offs

- **kagent `1.0.0-alpha3` vs `main` drift (HIGH):** the `grafana-mcp` sub-chart values, auto
  `RemoteMCPServer` name/url, and exact tool names may differ from the `main` docs used for research.
  Mitigation: a dedicated bring-up verification task inspects the live `RemoteMCPServer`s and
  `discoveredTools`, and the AgentTemplate bindings are adjusted to the alpha3 reality before E2E.
  Alternative considered: bumping the kagent pin (rejected — out of scope, could destabilize the existing
  substrate integration).
- **LLM-composed dashboard JSON validity (HIGH):** the agent must emit valid Grafana JSON; large/invalid
  JSON wastes context and can fail. Mitigation: compact template skeleton in the prompt, a small number of
  panels, restricted panel types, `list_datasources` for the data source, Grafana API validation with
  bounded retry, and `patch_dashboard` (small payloads) for edits. Alternative considered: a deterministic
  custom "dashboard builder" MCP tool (more reliable, but adds a custom service to build/deploy/document —
  deferred as hardening, and less on-theme for an "agent creates the dashboard" demo).
- **Context budget (MEDIUM):** binding ~10–12 tools + dashboard JSON on a 32k-context model can be tight.
  Mitigation: bind only the needed tool subset; keep dashboards small; use `get_dashboard_summary`
  (low-context) over `get_dashboard_by_uid` for planning edits.
- **Prometheus MCP HTTP transport config (MEDIUM):** the `pab1it0` server defaults to stdio and binds
  `127.0.0.1`; in-cluster use needs HTTP transport + `0.0.0.0` bind + the correct MCP path/port. Mitigation:
  set chart values explicitly and verify the `RemoteMCPServer` reaches `ACCEPTED=True`.
- **Boutique images / label set (LOW-MEDIUM):** upstream manifests pull Google sample images; the exact
  pod/service labels used to scope PromQL must be confirmed at bring-up. Mitigation: confirm via
  `get_targets`/`list_metrics` and `k8s_get_resources`; keep the PromQL namespace-scoped (robust to label
  changes).
- **Two MCP servers vs one (trade-off):** using both Grafana MCP and Prometheus MCP is clearer and maps to
  the FRs, at the cost of one more deployment and more bound tools. Accepted for pedagogy; the single-server
  alternative (Grafana MCP also queries Prometheus) is documented as the fallback if context/complexity
  becomes a problem.
- **Dev-host kind bootstrap (ENVIRONMENT, not a spec risk):** the authoring host has a **ZFS root**
  (`zpcachyos/ROOT/cos`) on a custom kernel (7.2.9). The `kindest/node` image's cAdvisor cannot read that
  root device, so the kubelet/apiserver never start and **no kind cluster can be created on this host**
  (reproduced with a minimal cluster). Consequence: live-cluster validation (T-005 bring-up, T-009 tool
  discovery, T-014 E2E, and the live parts of T-006/007/008/010/012) cannot be executed in this dev
  environment and must be confirmed by running `make up` + `scripts/verify-monitoring.sh` on the workshop
  (non-ZFS) hardware. All client-side validation (helm template, kustomize, YAML, bash -n) has been done.
