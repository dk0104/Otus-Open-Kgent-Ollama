#!/usr/bin/env bash
# Chat with the "k8s-expert" agent from your terminal.
#
# Usage:
#   ./scripts/chat.sh "Why does my pod stay in Pending?"
#
# The kagent CLI reaches the controller at localhost:8083 and, when nothing is
# listening there, runs `kubectl port-forward` against the kagent-controller
# Service automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kagent kubectl jq

TASK="${1:?Usage: $0 '<your question>'}"

info "looking up an existing AgentInstance for 'k8s-expert'..."
INSTANCE_ID="$(kagent get agent-instance -o json 2>/dev/null \
  | jq -r '[.agentInstances[] | select(.agentTemplate.name == "k8s-expert")] | sort_by(.createdAt) | last | .id // empty' 2>/dev/null)"

if [[ -z "${INSTANCE_ID:-}" || "$INSTANCE_ID" == "null" ]]; then
  info "none found; creating a new AgentInstance"
  run kagent create agent-instance --harness kagent --agent-template k8s-expert
  INSTANCE_ID="$(kagent get agent-instance -o json \
    | jq -r '[.agentInstances[] | select(.agentTemplate.name == "k8s-expert")] | sort_by(.createdAt) | last | .id')"
fi

ok "using AgentInstance ${INSTANCE_ID}"
echo
run kagent invoke --agent-instance "$INSTANCE_ID" --task "$TASK"
