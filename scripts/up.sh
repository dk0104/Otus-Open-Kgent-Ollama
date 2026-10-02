#!/usr/bin/env bash
# Bring up the full local stack, idempotently:
#
#   kind cluster -> Agent Substrate -> kagent -> Ollama -> Harness + AgentTemplate
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

run helm upgrade --install kagent "$KAGENT_CHART" \
  --version "$KAGENT_VERSION" --namespace "$KAGENT_NAMESPACE" --create-namespace \
  --timeout 10m \
  --set providers.ollama.model="${OLLAMA_MODEL}" \
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
# 5. Harness + AgentTemplate
# ---------------------------------------------------------------------------
info "applying Harness and AgentTemplate"
run kubectl apply -f "$ROOT_DIR/manifests/kagent/harness.yaml"
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
  err "  kubectl -n ${KAGENT_NAMESPACE} logs -l app.kubernetes.io/component=controller --tail=100"
  exit 1
fi
ok "agent 'k8s-expert' is ready"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

${c_green}The local AI agent stack is up.${c_reset}

  Cluster      : kind-${CLUSTER_NAME}
  Agent        : k8s-expert  (model: ${OLLAMA_MODEL} via in-cluster Ollama)

Next steps:

  # Chat with the agent from your terminal
  ./scripts/chat.sh "What is the difference between a Deployment and a StatefulSet?"

  # Open the kagent web UI
  ./scripts/ui.sh

  # Inspect the state
  ./scripts/status.sh

  # Tear everything down
  ./scripts/down.sh

EOF
