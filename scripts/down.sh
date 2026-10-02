#!/usr/bin/env bash
# Tear down the kind cluster (and everything inside it).
#
# Usage:
#   ./scripts/down.sh          # delete the cluster after confirmation
#   ./scripts/down.sh --yes    # skip confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kind kubectl

YES="${1:-}"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "kind cluster '${CLUSTER_NAME}' does not exist; nothing to do"
  exit 0
fi

if [[ "$YES" != "--yes" ]]; then
  read -r -p "Delete kind cluster '${CLUSTER_NAME}' and ALL state inside it (ollama models, agents, ...)? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "aborted"; exit 0; }
fi

run kind delete cluster --name "$CLUSTER_NAME"
ok "cluster '${CLUSTER_NAME}' deleted"
