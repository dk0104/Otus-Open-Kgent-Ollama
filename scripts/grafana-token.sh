#!/usr/bin/env bash
# grafana-token.sh — bootstrap a Grafana ServiceAccount + API token for the
# Grafana MCP server and store the token in the Secret the kagent chart
# references.
#
# Why: the kagent `grafana-mcp` sub-chart talks to Grafana with a ServiceAccount
# API token (env var GRAFANA_SERVICE_ACCOUNT_TOKEN). The kps chart ships Grafana
# with a fixed admin user but no ServiceAccount, so this script creates one.
#
# Idempotent (safe to re-run as part of `make up`):
#   * Reuses the ServiceAccount by name (does not create duplicates).
#   * Resets the SA to exactly one token (deletes the old, creates a fresh one).
#   * Re-creates the K8s Secret with `kubectl apply` (converges, no "already
#     exists" failure).
#
# Precondition: the kps Grafana is Ready (it is, after `make up` section 6).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl jq curl

# Grafana admin credentials (set in config/kps-values.yaml: adminUser/adminPassword).
# Overridable via environment.
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

SA_NAME="kagent-mcp"          # Grafana ServiceAccount name (role Editor)
TOKEN_NAME="kagent-mcp-token" # token name within the SA
ROLE="Editor"                 # enough to create folders + dashboards
SECRET_NAME="grafana-mcp-token"
SECRET_NAMESPACE="$KAGENT_NAMESPACE"
SVC_NAME="kps-grafana"        # kps Grafana service (release "kps")
SVC_PORT="80"                 # kps Grafana service port
LOCAL_PORT="3000"             # local port for the port-forward

info "bootstrapping Grafana ServiceAccount '${SA_NAME}' + token -> ${SECRET_NAMESPACE}/${SECRET_NAME}"

# 1. Port-forward the Grafana service (svc port 80 -> local 3000).
info "port-forwarding ${MONITORING_NAMESPACE}/${SVC_NAME}:${SVC_PORT} -> localhost:${LOCAL_PORT}"
kubectl -n "$MONITORING_NAMESPACE" port-forward "svc/${SVC_NAME}" "${LOCAL_PORT}:${SVC_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Wait until Grafana answers /api/health.
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null 2>&1 \
  || { err "Grafana did not become reachable on localhost:${LOCAL_PORT}"; exit 1; }
ok "Grafana is reachable"

auth=(-u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}")
base="http://127.0.0.1:${LOCAL_PORT}/api"

# 2. Ensure the ServiceAccount exists (reuse by name).
#    Grafana API: GET /api/serviceaccounts/search -> {serviceAccounts: [...]}
sa_id="$(curl -sf "${auth[@]}" "${base}/serviceaccounts/search?perpage=1000" \
  | jq -r --arg n "${SA_NAME}" '.serviceAccounts[]? | select(.name==$n) | .id' | head -n1 || true)"
if [[ -z "${sa_id}" || "${sa_id}" == "null" ]]; then
  info "creating Grafana ServiceAccount '${SA_NAME}' (role ${ROLE})"
  sa_id="$(curl -sf "${auth[@]}" -X POST "${base}/serviceaccounts" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "${SA_NAME}" --arg r "${ROLE}" '{name:$n, role:$r}')" \
    | jq -r .id)"
fi
[[ -n "${sa_id}" && "${sa_id}" != "null" ]] || { err "could not resolve ServiceAccount id"; exit 1; }
ok "ServiceAccount '${SA_NAME}' (id=${sa_id})"

# 3. Reset the SA to exactly one token: delete existing, create a fresh one.
mapfile -t old_tokens < <(curl -sf "${auth[@]}" "${base}/serviceaccounts/${sa_id}/tokens" \
  | jq -r '.[].id' || true)
for tid in "${old_tokens[@]:-}"; do
  [[ -n "${tid}" && "${tid}" != "null" ]] || continue
  curl -sf "${auth[@]}" -X DELETE "${base}/serviceaccounts/${sa_id}/tokens/${tid}" >/dev/null || true
done

info "creating token '${TOKEN_NAME}' (role ${ROLE})"
token="$(curl -sf "${auth[@]}" -X POST "${base}/serviceaccounts/${sa_id}/tokens" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "${TOKEN_NAME}" --arg r "${ROLE}" '{name:$n, role:$r}')" \
  | jq -r .key)"
[[ -n "${token}" && "${token}" != "null" ]] || { err "Grafana token creation failed"; exit 1; }
ok "Grafana token created"

# 4. Store the token in the Secret the kagent grafana-mcp sub-chart references
#    (env var GRAFANA_SERVICE_ACCOUNT_TOKEN). `apply` makes re-runs idempotent.
kubectl -n "$SECRET_NAMESPACE" create secret generic "${SECRET_NAME}" \
  --from-literal=GRAFANA_SERVICE_ACCOUNT_TOKEN="${token}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "stored token in ${SECRET_NAMESPACE}/${SECRET_NAME} (key GRAFANA_SERVICE_ACCOUNT_TOKEN)"

# 5. Verify the token authenticates (GET /api/org -> 200).
if curl -sf -H "Authorization: Bearer ${token}" "${base}/org" >/dev/null 2>&1; then
  ok "token verified (GET /api/org -> 200)"
else
  err "token did NOT authenticate against Grafana"
  exit 1
fi
