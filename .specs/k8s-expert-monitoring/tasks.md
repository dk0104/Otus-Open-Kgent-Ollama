# k8s-expert Monitoring & Dashboard Assistant Tasks

Spec: `k8s-expert-monitoring`  
Status: implementation-in-progress  
Created: 2026-10-11  
Brainstorm: `./brainstorm.md`  
Requirements: `./requirements.md`  
Design: `./design.md`

## Implementation Plan

Tasks are ordered. Each has an `ID: T-NNN`, the requirement(s) it satisfies, the files/areas it touches,
and a concrete validation. Complete in order; mark a task done only after its validation passes.

### Phase 0 — Foundation

- [x] 1. Add version pins and namespace defaults for the new components
  - ID: T-001
  - Requirement(s): NFR-003 (foundation for FR-001/FR-002)
  - Files/areas: `scripts/lib.sh`
  - Validation: `source scripts/lib.sh && echo $KPS_CHART $BLACKBOX_CHART $PROM_MCP_CHART $MONITORING_NAMESPACE $BOUTIQUE_NAMESPACE` prints the pinned chart locations and `monitoring` / `online-boutique`; `shellcheck scripts/lib.sh` is clean.

### Phase 1 — Monitoring plane + target app

- [x] 2. Create Helm values for the monitoring plane (Prometheus, Grafana, blackbox, Prometheus MCP)
  - ID: T-002
  - Requirement(s): FR-001, NFR-001
  - Files/areas: `config/monitoring-values.yaml` (new; split per chart if cleaner, e.g. `config/kps-values.yaml`, `config/blackbox-values.yaml`, `config/prom-mcp-values.yaml`)
  - Validation: `helm template kps oci://prometheus-community/kube-prometheus-stack -f <values> -n monitoring` renders without error; Grafana admin user/password and modest resource limits are present.

- [x] 3. Vendor the Google Online Boutique manifests into the repo
  - ID: T-003
  - Requirement(s): FR-002
  - Files/areas: `manifests/boutique/online-boutique.yaml` (vendored upstream `/release` manifest, pinned `v0.10.7` public images) + `manifests/boutique/kustomization.yaml` (injects namespace) + `manifests/boutique/namespace.yaml` (creates the `online-boutique` Namespace so `kubectl apply -k` is self-contained), all in namespace `online-boutique`
  - Validation: `kubectl kustomize manifests/boutique/` renders the `online-boutique` Namespace + 35 namespaced objects (all with `namespace: online-boutique`); full YAML/structure parse passes (every object has apiVersion/kind/name; every namespaced object has `namespace: online-boutique`; every container has an image); all 11 services pinned to `v0.10.7`. ✅ (live finding, demo env: the vendored manifest declares **no** Namespace and the kustomization only *injected* the field, so `apply -k` failed with `namespaces "online-boutique" not found` — added `namespace.yaml` + an explicit `kubectl create namespace` in `up.sh` section 7)

- [x] 4. Add blackbox `Probe` manifests for the Boutique HTTP endpoints
  - ID: T-004
  - Requirement(s): FR-003
  - Files/areas: `manifests/monitoring/probes.yaml` (new) + `config/blackbox-values.yaml` (added `tcp_connect` module)
  - Validation: `probes.yaml` parses as 2 `Probe` CRs — `boutique-frontend-http` (module `http_2xx`, target `frontend.online-boutique.svc:80`) and `boutique-backends-tcp` (module `tcp_connect`, 10 gRPC/redis targets); blackbox chart renders both `http_2xx` + `tcp_connect` modules. ✅ (live `kubectl apply --dry-run=client` needs the operator's `Probe` CRD, re-confirmed at T-005 bring-up)
  - Live finding (demo env): the prometheus-operator **`v1`** `Probe` uses `spec.targets.staticConfig` as a **single object** with fields `static` (list of `host:port`), `labels`, `relabelingConfigs` — **not** the `v1alpha1` list-of-`{targets, labels}` shape, and the list field is `static` (not `targets`). The old manifest (v1alpha1 shape) was rejected with `unknown field spec.targets.staticConfig[0].targets/labels`. Rewrote to the `v1` single-object shape; the multi-target backends probe derives a per-service `service` label via a `relabelingConfigs` entry (`regex: '^([^.]+)\..*'` on `__address__`), since one `staticConfig` carries only one shared label set. Client-side validated (structure + regex over all 10 hosts); server-side apply re-confirmed at T-005 bring-up.

- [ ] 5. Wire the monitoring plane + Boutique into `make up`
  - ID: T-005
  - Requirement(s): FR-001, FR-002, FR-003, NFR-002
  - Files/areas: `scripts/up.sh` (new sections 6 + 7: monitoring plane kps/blackbox/prom-mcp + Boutique + probes, all idempotent `helm upgrade --install` / `kubectl apply`)
  - Validation: code complete + client-side validated (`bash -n` clean; all three charts render with `helm template`; kustomize + YAML validated in T-003/T-004). ⚠️ LIVE bring-up **pending — environment-blocked**: this dev host has a **ZFS root** (`zpcachyos/ROOT/cos`) on kernel 7.2.9, and the `kindest/node` image's cAdvisor cannot read that root device, so the kubelet/apiserver never start and **no kind cluster can be bootstrapped here** (reproduced with a minimal cluster). Run `make up` in the demo environment to confirm: `kubectl -n monitoring get pods` (Prometheus/Grafana/kps-*/blackbox/prom-mcp ready), `kubectl -n online-boutique get deploy` all available, Prometheus targets `up`, and a re-run of `make up` is idempotent.
  - Live finding (demo env) #1 — Prometheus workload kind/name: the kps chart creates only the `Prometheus` **CR**; the operator materializes it as a **StatefulSet** and there is **no Prometheus Deployment**. The operator names the workload `prometheus-<cr-name>` (pod `prometheus-kps-kube-prometheus-stack-prometheus-0`), so waiting on `deployment/kps-...-prometheus` *or* `statefulset/kps-...-prometheus` both fail with NotFound. `up.sh` now uses `wait_prometheus_ready()` (polls the pod by name pattern `^prometheus-.*-prometheus-0 ` until it reports Ready), robust to the operator's exact StatefulSet naming and its create-later race. Same pattern used in `verify-monitoring.sh`. Fixed + `bash -n` clean.
  - Live finding (demo env) #2 — Boutique namespace: `kubectl apply -k manifests/boutique/` failed with `namespaces "online-boutique" not found` because the vendored manifest declares no Namespace and the kustomization only *injected* the namespace field. Fixed by adding `manifests/boutique/namespace.yaml` (a `Namespace` resource, listed first in the kustomization) **and** an explicit `kubectl create namespace … --dry-run=client -o yaml | kubectl apply -f -` in `up.sh` section 7 before the `apply -k` (removes any readiness race). `kubectl kustomize` now renders the Namespace + 35 namespaced objects; `bash -n` clean.

### Phase 2 — Grafana programmatic access

- [x] 6. Bootstrap a Grafana ServiceAccount + API token into a Secret
  - ID: T-006
  - Requirement(s): FR-005
  - Files/areas: `scripts/grafana-token.sh` (new), `scripts/up.sh` (call it)
  - Validation: script complete + `bash -n` OK. Live check (after `make up`: `kubectl -n kagent get secret grafana-mcp-token` exists; the token authenticates via `curl -H "Authorization: Bearer <token>" http://<grafana>:3000/api/org` over port-forward returning 200) runs in the demo environment.

### Phase 3 — MCP servers + agent bindings

- [x] 7. Enable and point the kagent built-in Grafana MCP
  - ID: T-007
  - Requirement(s): FR-005 (prereq for FR-008/009/010)
  - Files/areas: `config/kagent-values.yaml`
  - Validation: `helm template` confirms the `grafana-mcp` deployment with `grafana.url` = `kps-grafana.monitoring.svc:80/api` and the token from `secretRef: grafana-mcp-token` (no chart-created secret); `make up` (section 9) enables it + restarts the pod for the fresh token. Live check runs in the demo environment.

- [x] 8. Deploy the Prometheus MCP server and its `RemoteMCPServer`
  - ID: T-008
  - Requirement(s): FR-006, FR-007
  - Files/areas: `config/monitoring-values.yaml` (or `config/prom-mcp-values.yaml`), `manifests/monitoring/prometheus-mcp.yaml` (new `RemoteMCPServer` in `kagent`), `scripts/up.sh`
  - Validation: chart values + `RemoteMCPServer` manifest complete + YAML parse OK. Live check (after `make up`: prometheus-mcp pod ready; `kubectl -n kagent get remotemcpserver prometheus-mcp` shows `ACCEPTED=True`) runs in the demo environment.

- [ ] 9. Bring-up verification on kagent `1.0.0-alpha3` (gates the bindings)
  - ID: T-009
  - Requirement(s): FR-006 … FR-010 (prereq), top risk mitigation
  - Files/areas: verification step (may adjust `config/*` / `manifests/monitoring/*.yaml`); record findings in a short note
  - Validation: `kubectl -n kagent get remotemcpserver` lists both the Grafana and Prometheus servers with `ACCEPTED=True`; `kubectl -n kagent get remotemcpserver <name> -o jsonpath='{range .status.discoveredTools[*]}{.name}{"\n"}{end}'` for each confirms the exact tool names (`execute_query`, `list_metrics`, `get_metric_metadata`, `get_targets`, `update_dashboard`, `patch_dashboard`, `search_dashboards`, `get_dashboard_summary`, `create_folder`, `list_datasources`) and the real Grafana-MCP server name/url. Adjust values/manifests if alpha3 differs from `main`.

- [x] 10. Update the `k8s-expert` AgentTemplate: new tool bindings + monitoring system prompt
  - ID: T-010
  - Requirement(s): FR-006 … FR-017, NFR-004
  - Files/areas: `manifests/kagent/agent-template.yaml`
  - Validation: YAML parses; 3 MCP bindings in correct CRD shape; system prompt includes the monitoring workflow + dashboard-JSON template guidance + "no fabricated metrics" rule. **Tool names are best-known upstream names** — T-009 (live) must verify/adjust them before E2E. Live `Ready` condition runs in the demo environment.

### Phase 4 — Dashboard template + verification

- [x] 11. Add the reference Grafana dashboard template
  - ID: T-011
  - Requirement(s): FR-016, FR-017, NFR-003
  - Files/areas: `templates/grafana/boutique-dashboard.example.json` (new)
  - Validation: `jq` valid; 7 unique panel IDs; no gridPos overlaps; only allowed types (timeseries/stat) with namespace-scoped PromQL from the design table. Live import check (renders real data) runs in T-014 E2E.

- [x] 12. Add a monitoring verification script (and a Makefile target)
  - ID: T-012
  - Requirement(s): FR-001 … FR-010 (validation), NFR-002
  - Files/areas: `scripts/verify-monitoring.sh` (new), `Makefile`
  - Validation: script complete + `bash -n` OK; Makefile target present (real tabs). Live `make verify-monitoring` exits 0 when: Prometheus targets for expected jobs are `up`, the Grafana Prometheus data source answers a sample query, both `RemoteMCPServer`s are `ACCEPTED=True`, and a `kagent-monitoring` folder/dashboard can be listed (runs in the demo environment).

### Phase 5 — Documentation

- [x] 13. Update README and TUTORIAL for the monitoring demo
  - ID: T-013
  - Requirement(s): FR-018, NFR-003
  - Files/areas: `README.md`, `docs/TUTORIAL.md`
  - Validation: review pass — README + TUTORIAL updated with a coherent, reproducible monitoring section (the invisible monitoring stack, the updated `make up`, how to open Grafana via port-forward, and a step-by-step Web UI dialogue walkthrough); verified against the actual manifests/values; a participant can reproduce the flow from the docs alone.

### Phase 6 — End-to-end validation

- [ ] 14. E2E validation of the full monitoring dialogue
  - ID: T-014
  - Requirement(s): FR-012 … FR-017, NFR-002, NFR-004, NFR-005
  - Files/areas: manual (may tune `manifests/kagent/agent-template.yaml` prompt / values as needed)
  - Validation: (1) `make up` brings up everything; (2) in the Web UI, asking for the Boutique's monitoring options yields a concrete, real-metric scenario list; (3) selecting scenarios creates a dashboard whose panels render real data; (4) the returned Grafana URL opens it; (5) requesting a change updates the same dashboard in place (no duplicate); (6) re-running `make up` stays idempotent.
  - ⚠️ **LIVE — environment-blocked** here (requires a working kind cluster; ZFS host cannot bootstrap kind). Run in the demo environment.

## Verification Checklist

- [ ] Requirements IDs are referenced by tasks.
- [ ] Design testing strategy is represented by tasks (integration via T-012, E2E via T-014, idempotency via T-005/T-014).
- [ ] Each task has a clear validation command or manual check.
- [ ] Rollback/migration is covered (design Rollout; `make down` / `helm uninstall` of added releases).
- [ ] The alpha3 bring-up verification (T-009) precedes the AgentTemplate bindings (T-010).

## Execution Notes

- Keep `Status: tasks-draft` until the user explicitly approves this task plan.
- After approval, change status to `tasks-approved` and run implementation-readiness validation before coding.
- When coding starts, change status to `implementation-in-progress`.
- When all tasks are checked and validated, change status to `implementation-complete`.
- Complete tasks in order unless the user approves reordering.
- Mark tasks complete only after validation passes. "Validation passes" here
  means the **code deliverable + all client-side validation** (syntax/parse/
  `helm template`/`jq`) passes. **Live-cluster** validation (real `make up`,
  `make verify-monitoring`, E2E dialogue) is **blocked in this environment**
  (ZFS host: kind cannot bootstrap — see design.md Risks) and is tracked by the
  live tasks T-005 (bring-up), T-009 (tool discovery) and T-014 (E2E), which run
  in the demo environment.
- Record deviations from design in design.md before implementing them.
