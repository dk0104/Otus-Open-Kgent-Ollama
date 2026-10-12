# K8s Expert Monitoring Brainstorm

Spec: `k8s-expert-monitoring`  
Status: brainstorm-complete  
Created: 2026-10-11

## User Intent

Extend the existing kagent "k8s-expert" agent with monitoring capabilities so it can observe application and cluster state via Prometheus + Grafana and create Grafana dashboards through a natural-language conversation (primarily in the existing kagent Web UI, port 8082).

Context: This is a demo project (Otus course / workshop). The final project result is a presentation that builds on the existing kagent presentation (docs/presentation-kagent-ru.pdf), but the PRESENTATION IS OUT OF SCOPE for this spec (handled in a separate session). This spec covers only the working demo code, which will be made available to workshop participants (must be clean, reproducible, documented).

Key user answers:
- Purpose: demo project; outcome is a presentation, but only the technical demo is in scope here.
- Prometheus + Grafana are deployed automatically as part of the existing `make up` stack (alongside Ollama + kagent). The installation is "invisible" in the presentation — the cluster is just described as having the needed monitoring tools.
- Target application: Google Online Boutique microservices demo (https://github.com/GoogleCloudPlatform/microservices-demo), deployed into the cluster.
- Metrics depth: Option A chosen — monitor the app AS A KUBERNETES WORKLOAD (kube-state-metrics + node-exporter + cadvisor + blackbox-exporter). NO application code changes / no per-service Prometheus instrumentation (Options B and C rejected). Verified fact: Online Boutique does NOT expose Prometheus /metrics endpoints by default (only OTel traces / GCP Stackdriver), so infra-level scraping is the realistic source.
- Dialogue interface: Web UI (port 8082) is the primary focus; the CLI (make chat) remains secondary.
- Presentation/slides: out of scope (separate session). Code is the deliverable for participants.

Desired demo flow (multi-turn conversation in the Web UI):
U: "I have the multi-service app X (Online Boutique) installed; list the monitoring options for it."
A: Agent analyzes available metrics and lists all possible monitoring scenarios.
U: User chooses one or more scenarios and reviews the result.
A: Agent creates a Grafana dashboard. If needed, an interactive improvement cycle starts (agent adjusts the existing dashboard: panels, thresholds, scenarios).

Proposed approach:
1. Extend `make up` to deploy a monitoring stack via the kube-prometheus-stack Helm chart (bundles Prometheus, Grafana, kube-state-metrics, node-exporter, cadvisor; blackbox-exporter via values) plus deploy the Online Boutique via kubectl apply.
2. Extend the k8s-expert agent with custom tools: prometheus_query, prometheus_discover_metrics, grafana_create_dashboard, grafana_get/list_dashboards, grafana_update_dashboard (plus existing kubectl tools for app identification).
3. Web UI dialogue drives the tools in the agent loop; dashboard generation uses template-based Grafana JSON with a restricted panel-type set (graph/stat/gauge/table) and standardized PromQL patterns. Iterative updates modify the existing dashboard.
4. Update README/TUTORIAL for reproducibility for participants.

Constraints/risks:
- Hardware: 16 GB+ RAM (gVisor sandboxes + ~6 GB model), documented in README.
- Model must support tool calling (qwen3:8b default).
- Biggest technical risk: agent must generate VALID Grafana dashboard JSON. Mitigation: dashboard template/skeleton + restricted panel types + standardized PromQL patterns.
- Grafana needs API access (admin service account / token) for dashboard creation.
- Code must be reproducible and readable for participants.

Assumptions:
- "Improvement cycle" = agent adjusts the existing dashboard (add/change panels, thresholds, different scenarios), not a re-install.
- kube-prometheus-stack as the base (alternative: individual deployments) — to be refined in design.
- Grafana requires API access (admin service account/token) for dashboard creation.

Remaining doubts:
1. Language of the demo dialogue (German / Russian / English) — relevant for demo lines.
2. Exact depth of the improvement cycle (assumed above ok?).
3. Should the agent also suggest alerts/thresholds, or dashboards only?

Suggested spec slug: k8s-expert-monitoring

## Clarifying Questions Asked

- TODO: Record key questions asked one at a time and the user's answers.

## Proposed Approach

- TODO: Summarize the recommended direction before requirements are drafted.

## Assumptions

- TODO: List assumptions accepted during brainstorming.

## Remaining Doubts

- TODO: List unresolved questions, if any, and whether they block requirements.

## Decision

- [ ] User approved creating the spec skeleton and drafting requirements.
