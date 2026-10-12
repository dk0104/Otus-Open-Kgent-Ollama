# k8s-expert Monitoring & Dashboard Assistant Requirements

Spec: `k8s-expert-monitoring`  
Status: requirements-approved  
Created: 2026-10-11  
Brainstorm: `./brainstorm.md`

## Overview

Extend the kagent "k8s-expert" agent with Prometheus + Grafana monitoring capabilities: observe the
application (Google Online Boutique) and cluster state **as a Kubernetes workload**, and create/adjust
Grafana dashboards through a natural-language conversation in the kagent **Web UI** (port 8082). This is a
demo project; the **code is the deliverable** for workshop participants (must be clean, reproducible, and
documented). The presentation/slides are out of scope (separate session).

## Scope

### In Scope

- Automatic deployment of a Prometheus monitoring stack (Prometheus, Grafana, kube-state-metrics,
  node-exporter, cadvisor/kubelet metrics, blackbox-exporter) as part of the existing `make up` flow.
- Automatic deployment of the **Google Online Boutique** microservices demo as the monitored target app.
- New **agent tools** for `k8s-expert`: Prometheus query + metric/label discovery, and Grafana
  dashboard create/read/list/update via the Grafana HTTP API.
- A **Web UI conversation flow** (primary interface): list monitoring scenarios for an app → user selects
  one or more → agent creates a Grafana dashboard → user reviews → optional iterative improvement cycle.
- Template-based generation of **valid Grafana dashboard JSON** (restricted panel types) grounded in real
  Prometheus data.
- Updated **README/TUTORIAL** so participants can reproduce the flow.

### Out of Scope

- The presentation / slide deck (handled in a separate session; the monitoring install is "invisible" there).
- Application-level / business metrics by **instrumenting the Boutique services** (Options B/C from
  brainstorm — rejected). No Boutique source code changes.
- Production robustness: HA, multi-cluster, alerting rule management as a core feature, long-term retention.
- Making the **CLI** (`make chat`) the primary interface (it remains secondary / best-effort).

## User Stories

- As a **workshop demonstrator**, I want to ask the k8s-expert agent in the Web UI to list the monitoring
  options for the Online Boutique, so that I can showcase a natural-language monitoring workflow live.
- As a **workshop demonstrator**, I want the agent to create a working Grafana dashboard from my selected
  scenarios, so that the audience sees real, populated panels in the browser.
- As a **workshop demonstrator**, I want to ask the agent to adjust the dashboard (improvement cycle), so
  that I can show the agent iterating on its own output.
- As a **workshop participant** (code consumer), I want the stack and the conversation to be reproducible
  with the documented steps, so that I can set it up and experiment on my own machine.

## Functional Requirements

Use stable IDs and testable EARS-style statements.

**Monitoring stack & target app (deployment)**

- **FR-001**: WHEN the user runs `make up`, THE system SHALL deploy a Prometheus monitoring stack
  (Prometheus server, Grafana, kube-state-metrics, node-exporter, cadvisor/kubelet metrics,
  blackbox-exporter) into the kind cluster without manual intervention.
- **FR-002**: WHEN the user runs `make up`, THE system SHALL deploy the Google Online Boutique application
  into the cluster so that its workloads (Pods/Deployments/Services) are present and observable.
- **FR-003**: THE system SHALL configure Prometheus to scrape cluster-level metrics (kube-state-metrics,
  node-exporter, cadvisor, kubelet, apiserver, scheduler, controller-manager) and Online Boutique workload
  metrics (Pod CPU/memory, restarts, availability) via the deployed exporters.
- **FR-004**: THE system SHALL preconfigure Grafana with a Prometheus data source and make Grafana reachable
  to the user (e.g., port-forward) for browsing dashboards.
- **FR-005**: THE system SHALL provide Grafana API credentials (e.g., a service-account token) that the agent
  can use to create/read/update dashboards programmatically.

**Agent tools**

- **FR-006**: THE system SHALL provide the k8s-expert agent a tool to execute a PromQL query against
  Prometheus and return the resulting data.
- **FR-007**: THE system SHALL provide the k8s-expert agent a tool to discover available metrics and label
  values (e.g., metric names, label values, filterable by namespace/app) so it can ground scenario
  suggestions in real data.
- **FR-008**: THE system SHALL provide the k8s-expert agent a tool to create a Grafana dashboard via the
  Grafana HTTP API using provided dashboard JSON.
- **FR-009**: THE system SHALL provide the k8s-expert agent a tool to list and read existing Grafana
  dashboards (by folder/name/uid).
- **FR-010**: THE system SHALL provide the k8s-expert agent a tool to update an existing Grafana dashboard
  (in place) via the Grafana HTTP API.
- **FR-011**: THE system SHALL provide the k8s-expert agent a capability (existing or new tool) to identify
  applications and their workloads (Deployments/Services/Pods, namespace, labels) in the cluster, so it can
  map a user-named app (e.g., "Online Boutique") to concrete resources.

**Conversation flow (Web UI)**

- **FR-012**: WHEN the user asks, in the Web UI, for the monitoring options of a named application, THE agent
  SHALL analyze the available metrics (via FR-006/FR-007) and respond with a concrete list of monitoring
  scenarios for that application.
- **FR-013**: WHEN the user selects one or more scenarios, THE agent SHALL generate and create a Grafana
  dashboard (via FR-008) that covers the selected scenarios.
- **FR-014**: AFTER creating a dashboard, THE agent SHALL provide the user a way to open it (a Grafana URL or
  clear instructions).
- **FR-015**: IF the user requests a change to an already-created dashboard (improvement cycle), THE agent
  SHALL update the existing dashboard in place (via FR-010) rather than creating a duplicate.
- **FR-016**: THE agent SHALL generate dashboard content only as valid Grafana dashboard JSON restricted to
  the supported panel types (graph/timeseries, stat, gauge, table).

**Dashboard content**

- **FR-017**: THE agent SHALL populate each panel with a valid PromQL expression that visualizes the selected
  scenario (e.g., availability, CPU/memory usage, restart count, request latency) using real scraped data.

**Documentation & reproducibility**

- **FR-018**: THE system SHALL document, in README/TUTORIAL, how to bring up the monitoring stack and run the
  monitoring conversation end-to-end, so that a participant can reproduce it.

## Non-Functional Requirements

- **NFR-001**: THE monitoring stack SHALL fit within the documented hardware constraints (16 GB+ RAM, ~30 GB
  disk) already stated for the project.
- **NFR-002**: `make up` SHALL be idempotent — re-running it SHALL NOT break or duplicate the monitoring stack
  or the target application.
- **NFR-003**: THE code, manifests, and scripts SHALL be readable and sufficiently documented for workshop
  participants to understand and modify.
- **NFR-004**: THE agent SHALL ground its monitoring answers in real Prometheus data (no fabricated metrics);
  it SHALL report clearly when a metric or app is not found.
- **NFR-005**: THE system SHALL create dashboards in a controlled location (a dedicated Grafana folder and/or
  consistent naming) to avoid clutter and enable in-place updates.
- **NFR-006**: THE agent SHALL rely on tool calling; a model without tool-calling support is a known limitation
  (consistent with existing project guidance).

## Acceptance Criteria

- [ ] `make up` brings up the monitoring stack **and** the Online Boutique; Prometheus is scraping (targets
      up) and Grafana is reachable with a working Prometheus data source.
- [ ] In the Web UI, when asked for monitoring options for the Online Boutique, the agent returns a concrete
      list of monitoring scenarios grounded in real metrics.
- [ ] When the user selects one or more scenarios, the agent creates a Grafana dashboard whose panels render
      real data (not empty) in the browser.
- [ ] When the user requests an adjustment, the agent updates the same dashboard in place (no duplicate).
- [ ] A participant can reproduce the whole flow using only the documented steps.

## Edge Cases

- Target app not deployed (Boutique missing) → the agent detects this and prompts the user to deploy it
  (or runs/notes `make up`), instead of inventing scenarios.
- Prometheus not ready / no metrics yet for a workload → the agent reports the empty state clearly (NFR-004).
- Unknown or unsupported scenario requested by the user → the agent explains what it can and cannot do.
- Grafana API authentication/authorization failure → the agent surfaces a clear, actionable error.
- Model produces invalid Grafana JSON → the system validates and either retries or reports the error without
  corrupting existing dashboards.
- Repeated dashboard requests for the same app/scenarios → the agent updates the existing dashboard
  (FR-015) rather than creating duplicates.

## Dependencies and Constraints

- **kagent 1.x tool system** — the mechanism for defining/attaching custom tools to the `k8s-expert` agent
  (to be confirmed in design).
- **Grafana HTTP API** + service-account credentials for programmatic dashboard management.
- **Prometheus HTTP API** for querying and metric discovery.
- **Monitoring stack base** — proposed `kube-prometheus-stack` Helm chart (alternative: individual
  deployments); to be finalized in design.
- **Google Online Boutique** manifests (upstream repo) for the target app.
- **Hardware:** 16 GB+ RAM and ~30 GB disk (existing constraint; the stack adds resource demand).
- **Model:** must support tool calling (qwen3:8b default).

## Open Questions

- [ ] Language of the demo dialogue (German / Russian / English) — affects demo scripting, not code behavior.
- [ ] Exact depth of the improvement cycle (assumed: adjust panels/thresholds/scenarios of an existing
      dashboard; confirm).
- [ ] Should the agent also propose **alerts/thresholds**, or is dashboards-only the intended scope?
- [ ] Confirm the monitoring-stack base: `kube-prometheus-stack` chart vs. hand-rolled deployments.
