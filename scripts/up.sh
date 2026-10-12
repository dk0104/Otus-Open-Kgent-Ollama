#!/usr/bin/env bash
# Bring up the full local stack, idempotently:
#
#   kind cluster -> Agent Substrate -> kagent -> Ollama -> Harness
#   -> monitoring plane (Prometheus + Grafana + blackbox + Prometheus MCP)
#   -> Google Online Boutique + availability probes
#   -> Grafana ServiceAccount + API token
#   -> enable built-in Grafana MCP + register Prometheus MCP (RemoteMCPServer x2)
#   -> AgentTemplate (monitoring tool bindings)
#
# Safe to re-run: every step is `helm upgrade --install`, `kubectl apply`, or a
# guarded `create`. Re-run after a failure picks up where it left off.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kind kubectl helm jq openssl docker
require_ate

info "stack: cluster=${CLUSTER_NAME} node=${KIND_NODE_IMAGE} kagent=${KAGENT_VERSION} substrate=${SUBSTRATE_VERSION} model=${OLLAMA_MODEL}"

# ---------------------------------------------------------------------------
# 1. kind cluster
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if kubectl --context "kind-${CLUSTER_NAME}" cluster-info >/dev/null 2>&1; then
    ok "kind cluster '${CLUSTER_NAME}' already exists and is reachable; skipping create"
  else
    warn "kind cluster '${CLUSTER_NAME}' exists but does not answer; recreating"
    kind delete cluster --name "$CLUSTER_NAME"
  fi
fi
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "creating kind cluster '${CLUSTER_NAME}' (${KIND_NODE_IMAGE})"
  sed "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" "$ROOT_DIR/config/kind-cluster.yaml" \
    | kind create cluster --image "$KIND_NODE_IMAGE" --config=-
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ---------------------------------------------------------------------------
# 2. Agent Substrate (ate-system)
# ---------------------------------------------------------------------------
info "installing Agent Substrate ${SUBSTRATE_VERSION} into ${ATE_NAMESPACE}"
run helm upgrade --install substrate-crds "$SUBSTRATE_CRDS_CHART" \
  --version "$SUBSTRATE_VERSION" --namespace "$ATE_NAMESPACE" --create-namespace

# Deliberately no --wait here: pods cannot become ready until the identity
# material below exists.
run helm upgrade --install substrate "$SUBSTRATE_CHART" \
  --version "$SUBSTRATE_VERSION" --namespace "$ATE_NAMESPACE"

info "bootstrapping Agent Substrate identity material (mTLS CA pools + JWT pools)"

# CA pools that sign service DNS and pod identity certificates.
if kubectl -n podcertificate-controller-system get secret service-dns-ca-pool >/dev/null 2>&1; then
  ok "service-dns-ca-pool already present"
else
  run kubectl ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool \
    --secret-namespace=podcertificate-controller-system
fi
if kubectl -n podcertificate-controller-system get secret pod-identity-ca-pool >/dev/null 2>&1; then
  ok "pod-identity-ca-pool already present"
else
  run kubectl ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool \
    --secret-namespace=podcertificate-controller-system
fi

# Actor identity pools.
if kubectl -n "$ATE_NAMESPACE" get secret actor-id-jwt-pool >/dev/null 2>&1; then
  ok "actor-id-jwt-pool already present"
else
  run kubectl ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool \
    --secret-namespace="$ATE_NAMESPACE"
fi
if kubectl -n "$ATE_NAMESPACE" get secret actor-id-ca-pool >/dev/null 2>&1; then
  ok "actor-id-ca-pool already present"
else
  run kubectl ate admin make-ca-pool --ca-id=1 --name=actor-id-ca-pool \
    --secret-namespace="$ATE_NAMESPACE"
fi

# CA pool the atenet egress gateway uses to mint certificates for HTTPS
# interception (MITM). The substrate chart's atenet-egress Deployment mounts
# this secret; without it the pod stays in ContainerCreating and the second
# `helm upgrade substrate --wait` below times out.
if kubectl -n "$ATE_NAMESPACE" get secret egress-mitm-ca-pool >/dev/null 2>&1; then
  ok "egress-mitm-ca-pool already present"
else
  run kubectl ate admin make-ca-pool --ca-id=1 --name=egress-mitm-ca-pool \
    --secret-namespace="$ATE_NAMESPACE"
fi

# Extract the actor identity root certificate into the secret the API server reads.
info "deriving actor-id-ca-certs from actor-id-ca-pool root"
actor_id_ca_root="$(kubectl get secret actor-id-ca-pool -n "$ATE_NAMESPACE" \
  -o jsonpath='{.data.pool}' | base64 --decode \
  | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem)"
kubectl -n "$ATE_NAMESPACE" create secret generic actor-id-ca-certs \
  --from-literal=ca.crt="${actor_id_ca_root}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Authentication config. Derive the issuer from the cluster instead of assuming
# one (kind 1.37 advertises https://kubernetes.default.svc.cluster.local).
info "creating ate-api-authentication configmap"
k8s_issuer="$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)"
kubectl -n "$ATE_NAMESPACE" create configmap ate-api-authentication \
  --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${k8s_issuer}
  audiences: [api.${ATE_NAMESPACE}.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
" --dry-run=client -o yaml | kubectl apply -f -

# Roll out again so pods mount the identity material, and wait this time.
run helm upgrade substrate "$SUBSTRATE_CHART" \
  --version "$SUBSTRATE_VERSION" --namespace "$ATE_NAMESPACE" \
  --reuse-values --wait --timeout 10m
ok "Agent Substrate is ready"

# ---------------------------------------------------------------------------
# 3. kagent (kagent namespace)
# ---------------------------------------------------------------------------
info "installing kagent ${KAGENT_VERSION} into ${KAGENT_NAMESPACE}"
run helm upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  --version "$KAGENT_VERSION" --namespace "$KAGENT_NAMESPACE" --create-namespace --wait

# NOTE: the built-in grafana-mcp is DEFERRED here (enabled=false). Its token
# Secret (grafana-mcp-token) only exists once Grafana is up and the token is
# bootstrapped (section 8). It is re-enabled in section 9 with a plain `helm
# upgrade` (no override) + a Pod restart, so the grafana-mcp Pod always starts
# with a valid, current token.
run helm upgrade --install kagent "$KAGENT_CHART" \
  --version "$KAGENT_VERSION" --namespace "$KAGENT_NAMESPACE" --create-namespace \
  --timeout 10m \
  --set providers.ollama.model="${OLLAMA_MODEL}" \
  --set grafana-mcp.enabled=false \
  -f "$ROOT_DIR/config/kagent-values.yaml"

run kubectl -n "$KAGENT_NAMESPACE" rollout status deployment/kagent-controller --timeout=300s
run kubectl -n "$KAGENT_NAMESPACE" rollout status deployment/kagent-ui --timeout=300s
ok "kagent is ready"

# ---------------------------------------------------------------------------
# 4. Ollama (ollama namespace)
# ---------------------------------------------------------------------------
info "deploying Ollama into ${OLLAMA_NAMESPACE}"
run kubectl apply -f "$ROOT_DIR/manifests/ollama/ollama.yaml"
run kubectl -n "$OLLAMA_NAMESPACE" rollout status deployment/ollama --timeout=300s

info "pulling model '${OLLAMA_MODEL}' (first run downloads several GB; be patient)"
run kubectl -n "$OLLAMA_NAMESPACE" exec deploy/ollama -- ollama pull "$OLLAMA_MODEL"
run kubectl -n "$OLLAMA_NAMESPACE" exec deploy/ollama -- ollama list

# ---------------------------------------------------------------------------
# 5. Harness
#    (The AgentTemplate is applied LAST, in section 11, once both Remote MCP
#     servers exist, so its tool bindings resolve on first admission.)
# ---------------------------------------------------------------------------
info "applying the Harness"
run kubectl apply -f "$ROOT_DIR/manifests/kagent/harness.yaml"
ok "harness is applied"

# ---------------------------------------------------------------------------
# 6. Monitoring plane (monitoring namespace)
# ---------------------------------------------------------------------------
info "installing the monitoring plane into ${MONITORING_NAMESPACE}"

# Ensure the prometheus-community Helm repo is present (kube-prometheus-stack +
# blackbox-exporter come from it; the Prometheus MCP chart is pulled from OCI).
if ! helm repo list -q 2>/dev/null | grep -qx "$PROMETHEUS_COMMUNITY_REPO_NAME"; then
  run helm repo add "$PROMETHEUS_COMMUNITY_REPO_NAME" "$PROMETHEUS_COMMUNITY_REPO_URL"
fi
run helm repo update "$PROMETHEUS_COMMUNITY_REPO_NAME"

# kube-prometheus-stack: Prometheus + Grafana + operator + node/kube-state exporters.
# No --wait here: Prometheus/Alertmanager are operator CRs reconciled into
# deployments a moment later; we wait for them explicitly below.
run helm upgrade --install kps "$KPS_CHART" \
  --version "$KPS_VERSION" --namespace "$MONITORING_NAMESPACE" --create-namespace \
  -f "$ROOT_DIR/config/kps-values.yaml"

# blackbox-exporter: the prober the Boutique `Probe` resources call.
run helm upgrade --install blackbox-exporter "$BLACKBOX_CHART" \
  --version "$BLACKBOX_VERSION" --namespace "$MONITORING_NAMESPACE" \
  -f "$ROOT_DIR/config/blackbox-values.yaml"

# prometheus-mcp-server: PromQL + metric-discovery tools exposed to the agent.
run helm upgrade --install prometheus-mcp "$PROM_MCP_CHART" \
  --version "$PROM_MCP_VERSION" --namespace "$MONITORING_NAMESPACE" \
  -f "$ROOT_DIR/config/prom-mcp-values.yaml"

# Wait for the Prometheus pod to become Ready. The prometheus-operator creates
# the Prometheus workload from the `Prometheus` CR as a StatefulSet a moment
# after the operator itself is ready, and names the pod `prometheus-<cr-name>-0`
# (e.g. `prometheus-kps-kube-prometheus-stack-prometheus-0`). We poll for that
# pod by name pattern (robust to the operator's exact StatefulSet naming) until
# it reports Ready — this also tolerates the operator's create-later race.
wait_prometheus_ready() { # $1 = timeout seconds
  local timeout="$1" deadline line
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    line="$(kubectl -n "$MONITORING_NAMESPACE" get pods \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
      | grep -E '^prometheus-.*-prometheus-0 ' | head -n1 || true)"
    if [[ -n "${line}" && "${line##* }" == "True" ]]; then
      return 0
    fi
    sleep 5
  done
  err "Prometheus pod never became Ready within ${timeout}s (last='${line:-<not found>}')"
  err "  kubectl -n ${MONITORING_NAMESPACE} get pods"
  return 1
}

# Wait for the operator, then the operator-managed Prometheus pod, plus Grafana
# and the two side MCP/prober pods (real deployments, created by their charts).
run kubectl -n "$MONITORING_NAMESPACE" rollout status deployment/kps-kube-prometheus-stack-operator --timeout=300s
wait_prometheus_ready 600
run kubectl -n "$MONITORING_NAMESPACE" rollout status deployment/kps-grafana --timeout=300s
run kubectl -n "$MONITORING_NAMESPACE" rollout status deployment/blackbox-exporter --timeout=300s
run kubectl -n "$MONITORING_NAMESPACE" rollout status deployment/prometheus-mcp --timeout=300s
ok "monitoring plane is ready (Prometheus, Grafana, blackbox-exporter, prometheus-mcp)"

# ---------------------------------------------------------------------------
# 7. Google Online Boutique (online-boutique namespace) + availability probes
# ---------------------------------------------------------------------------
info "deploying Google Online Boutique into ${BOUTIQUE_NAMESPACE}"
# Ensure the namespace exists before the namespaced objects are applied (the
# kustomization also declares it, so a bare `kubectl apply -k` is self-contained;
# the explicit create just removes any namespace-readiness race).
kubectl create namespace "$BOUTIQUE_NAMESPACE" --dry-run=client -o yaml | run kubectl apply -f -
run kubectl apply -k "$ROOT_DIR/manifests/boutique/"
run kubectl -n "$BOUTIQUE_NAMESPACE" rollout status deployment/frontend --timeout=600s

info "applying blackbox availability probes for the Boutique"
run kubectl apply -f "$ROOT_DIR/manifests/monitoring/probes.yaml"
ok "Online Boutique is up in ${BOUTIQUE_NAMESPACE} (probes active)"

# Wait for a RemoteMCPServer to reach the Accepted condition (tools discovered).
wait_rmc_accepted() { # $1 = remotemcpserver name
  local name="$1" acc="" i
  for i in $(seq 1 60); do
    acc="$(kubectl -n "$KAGENT_NAMESPACE" get remotemcpserver "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [[ "$acc" == "True" ]] && return 0
    sleep 5
  done
  err "RemoteMCPServer '$name' did not become Accepted (status='${acc:-<none>}')"
  err "  kubectl -n ${KAGENT_NAMESPACE} get remotemcpserver ${name} -o yaml"
  return 1
}

# ---------------------------------------------------------------------------
# 8. Grafana ServiceAccount + API token (Secret grafana-mcp-token in kagent)
# ---------------------------------------------------------------------------
info "creating the Grafana ServiceAccount + API token"
run bash "$ROOT_DIR/scripts/grafana-token.sh"

# ---------------------------------------------------------------------------
# 9. Enable the built-in Grafana MCP (now that the token Secret exists)
# ---------------------------------------------------------------------------
info "enabling the kagent built-in Grafana MCP"
run helm upgrade --install kagent "$KAGENT_CHART" \
  --version "$KAGENT_VERSION" --namespace "$KAGENT_NAMESPACE" \
  --timeout 10m \
  --set providers.ollama.model="${OLLAMA_MODEL}" \
  -f "$ROOT_DIR/config/kagent-values.yaml"
# The token Secret was just refreshed; env is captured at Pod creation, so
# restart the grafana-mcp Pod to pick up the current token (idempotent).
run kubectl -n "$KAGENT_NAMESPACE" rollout restart deployment/kagent-grafana-mcp
run kubectl -n "$KAGENT_NAMESPACE" rollout status deployment/kagent-grafana-mcp --timeout=300s
wait_rmc_accepted "kagent-grafana-mcp"
ok "Grafana MCP is ready (RemoteMCPServer kagent-grafana-mcp)"

# ---------------------------------------------------------------------------
# 10. Prometheus MCP RemoteMCPServer (in kagent)
# ---------------------------------------------------------------------------
info "registering the Prometheus MCP as a RemoteMCPServer"
run kubectl apply -f "$ROOT_DIR/manifests/monitoring/prometheus-mcp.yaml"
wait_rmc_accepted "prometheus-mcp"
ok "RemoteMCPServer prometheus-mcp is registered"

# ---------------------------------------------------------------------------
# 11. AgentTemplate (applied last: its MCP tool bindings must resolve)
# ---------------------------------------------------------------------------
info "applying the k8s-expert AgentTemplate (with monitoring tool bindings)"
run kubectl apply -f "$ROOT_DIR/manifests/kagent/agent-template.yaml"

info "waiting for the AgentTemplate to be admitted and compiled (up to ~5m)"
ready=""
for _ in $(seq 1 60); do
  ready="$(kubectl -n "$KAGENT_NAMESPACE" get agenttemplate k8s-expert \
    -o jsonpath='{.status.harnesses[0].conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$ready" == "True" ]] && break
  sleep 5
done
if [[ "$ready" != "True" ]]; then
  err "AgentTemplate did not become Ready; inspect with:"
  err "  kubectl -n ${KAGENT_NAMESPACE} get agenttemplate k8s-expert -o yaml"
  err "  kubectl -n ${KAGENT_NAMESPACE} get remotemcpserver -o wide"
  err "  kubectl -n ${KAGENT_NAMESPACE} logs -l app.kubernetes.io/component=controller --tail=100"
  exit 1
fi
ok "agent 'k8s-expert' is ready (with Prometheus + Grafana tools)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

${c_green}The local AI agent stack is up.${c_reset}

  Cluster      : kind-${CLUSTER_NAME}
  Agent        : k8s-expert  (model: ${OLLAMA_MODEL} via in-cluster Ollama)
  Monitoring   : Prometheus + Grafana + blackbox in ${MONITORING_NAMESPACE}
  Target app   : Google Online Boutique in ${BOUTIQUE_NAMESPACE}

Next steps:

  # Ask the agent to build a monitoring dashboard for the Boutique (web UI)
  ./scripts/ui.sh

  # Or from the terminal
  ./scripts/chat.sh "List the monitoring options you can build for Online Boutique."

  # Inspect the state (includes the monitoring plane + Boutique)
  ./scripts/status.sh

  # Health-check the monitoring plane (exit 0 = OK)
  make verify-monitoring

  # Open Grafana in the browser
  kubectl -n monitoring port-forward svc/kps-grafana 3000:80
  # then visit http://localhost:3000 (admin/admin)

  # Tear everything down
  ./scripts/down.sh

EOF
