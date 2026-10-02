#!/usr/bin/env bash
# Open the kagent web UI in your browser via port-forward.
#
# The UI Service listens on 8080 inside the cluster; this forwards it to
# http://localhost:8082 on your machine. Keep this terminal running, then visit
# the URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl

info "forwarding kagent UI -> http://localhost:8082  (Ctrl-C to stop)"
echo
exec kubectl -n "$KAGENT_NAMESPACE" port-forward svc/kagent-ui 8082:8080
