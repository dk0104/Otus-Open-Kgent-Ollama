#!/usr/bin/env bash
# Print the state of the whole stack: cluster, substrate, kagent, ollama, agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl

section() { printf "\n${c_cyan}== %s ==${c_reset}\n" "$*"; }

section "kind"
kind get clusters 2>/dev/null || true

section "Agent Substrate (${ATE_NAMESPACE})"
kubectl get pods -n "$ATE_NAMESPACE" 2>/dev/null || echo "not installed"

section "kagent (${KAGENT_NAMESPACE})"
kubectl get pods -n "$KAGENT_NAMESPACE" 2>/dev/null || echo "not installed"
echo
kubectl -n "$KAGENT_NAMESPACE" get workerpools,harnesses,agenttemplates,modelconfigs 2>/dev/null || true

section "Ollama (${OLLAMA_NAMESPACE})"
kubectl get pods -n "$OLLAMA_NAMESPACE" 2>/dev/null || echo "not installed"
echo
kubectl -n "$OLLAMA_NAMESPACE" get pods 2>/dev/null | grep -q ollama \
  && kubectl -n "$OLLAMA_NAMESPACE" exec deploy/ollama -- ollama list 2>/dev/null || true

section "AgentInstances"
if command -v kagent >/dev/null 2>&1; then
  kagent get agent-instance 2>/dev/null || echo "(none — run ./scripts/chat.sh first)"
else
  echo "kagent CLI not installed (run make prereqs)"
fi
echo
