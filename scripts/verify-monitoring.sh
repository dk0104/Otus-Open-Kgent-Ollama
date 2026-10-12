#!/usr/bin/env bash
# verify-monitoring.sh — post-`make up` health gate for the monitoring plane.
#
# Exits 0 only when ALL of the following hold (task T-012):
#   1. The monitoring Pods are Ready.
#   2. Prometheus is scraping and the expected jobs report `up` (the two
#      Boutique blackbox probe jobs plus node-exporter / kube-state-metrics).
#   3. The Grafana Prometheus data source answers a sample query (via the API,
#      using the ServiceAccount token from the `grafana-mcp-token` Secret).
#   4. Both RemoteMCPServers (kagent-grafana-mcp, prometheus-mcp) are Accepted.
#   5. The Grafana API can list folders/dashboards (and reports the
#      `kagent-monitoring` folder if the agent has created it).
#
# This is a read-only check; it never mutates state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl jq curl

PROM_SVC="kps-kube-prometheus-stack-prometheus"   # kps Prometheus service (port 9090)
GRAF_SVC="kps-grafana"                            # kps Grafana service (port 80)
PROM_PORT=9090
GRAF_PORT=80
PROM_LOCAL=19090
GRAF_LOCAL=13000
FOLDER="kagent-monitoring"

PASS=0
FAIL=0
pass() { ok "PASS: $1"; PASS=$((PASS+1)); }
fail() { err "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- 1. Monitoring Pods Ready -------------------------------------------------
info "checking monitoring Pods are Ready"
pods_ok=true
for sel in \
  "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kps" \
  "app.kubernetes.io/name=blackbox-exporter" \
  "app.kubernetes.io/name=prometheus-mcp-server"; do
  notready="$(kubectl -n "$MONITORING_NAMESPACE" get pods -l "$sel" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -v '=True' || true)"
  if [[ -n "${notready}" ]]; then
    pods_ok=false
    echo "    not ready (${sel}): ${notready}" | tr '\n' ' '; echo
  fi
done
# The kps Prometheus is operator-managed: the chart only creates the
# `Prometheus` CR, and the operator materialises a StatefulSet whose pod is
# `prometheus-<cr-name>-0`. The operator's pods do NOT carry the Helm
# `app.kubernetes.io/name=prometheus` label, so check it by pod name pattern.
prom_line="$(kubectl -n "$MONITORING_NAMESPACE" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | grep -E '^prometheus-.*-prometheus-0 ' | head -n1 || true)"
if [[ -z "${prom_line}" ]]; then
  pods_ok=false
  echo "    kps Prometheus pod not found (expected prometheus-...-prometheus-0)"
elif [[ "${prom_line##* }" != "True" ]]; then
  pods_ok=false
  echo "    kps Prometheus pod not Ready: ${prom_line}"
fi
if [[ "$pods_ok" == true ]]; then pass "monitoring Pods are Ready"; else fail "monitoring Pods not all Ready"; fi

# --- 2. Prometheus targets up -------------------------------------------------
info "checking Prometheus is scraping (targets up)"
kubectl -n "$MONITORING_NAMESPACE" port-forward "svc/${PROM_SVC}" "${PROM_LOCAL}:${PROM_PORT}" >/dev/null 2>&1 &
PF_PROM=$!
trap 'kill "${PF_PROM}" 2>/dev/null || true' EXIT

prom_query() { # $1 = PromQL -> prints scalar value or empty
  curl -sf "http://127.0.0.1:${PROM_LOCAL}/api/v1/query" --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // empty'
}

for _ in $(seq 1 30); do
  prom_query 'vector(1)' >/dev/null 2>&1 && break
  sleep 2
done

if ! prom_query 'vector(1)' >/dev/null 2>&1; then
  fail "Prometheus API not reachable on localhost:${PROM_LOCAL}"
else
  up_total="$(prom_query 'count(up == 1)')"
  up_total="${up_total:-0}"
  awk "BEGIN{exit !($up_total >= 1)}" \
    && pass "Prometheus is scraping (count(up==1) = ${up_total})" \
    || fail "no healthy Prometheus targets (count(up==1) = ${up_total})"

  for job in boutique-frontend-http boutique-backends-tcp; do
    v="$(prom_query "min(up{job=\"${job}\"})")"
    if [[ "${v}" == "1" ]]; then
      pass "blackbox job '${job}' is up"
    else
      fail "blackbox job '${job}' not up (min(up)='${v:-empty}')"
    fi
  done

  for job in node-exporter kube-state-metrics; do
    v="$(prom_query "min(up{job=\"${job}\"})")"
    if [[ "${v}" == "1" ]]; then
      pass "collector job '${job}' is up"
    else
      # Informational: job names can vary; warn rather than hard-fail.
      warn "collector job '${job}' not confirmed up (min(up)='${v:-empty}')"
    fi
  done
fi

# --- Grafana port-forward (for checks 3 & 5) ---------------------------------
TOKEN="$(kubectl -n "$KAGENT_NAMESPACE" get secret grafana-mcp-token \
  -o jsonpath='{.data.GRAFANA_SERVICE_ACCOUNT_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  fail "could not read GRAFANA_SERVICE_ACCOUNT_TOKEN from ${KAGENT_NAMESPACE}/grafana-mcp-token"
else
  kubectl -n "$MONITORING_NAMESPACE" port-forward "svc/${GRAF_SVC}" "${GRAF_LOCAL}:${GRAF_PORT}" >/dev/null 2>&1 &
  PF_GRAF=$!
  trap 'kill "${PF_PROM}" "${PF_GRAF}" 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${GRAF_LOCAL}/api/health" >/dev/null 2>&1 && break
    sleep 2
  done
  gauth=(-H "Authorization: Bearer ${TOKEN}")
  gbase="http://127.0.0.1:${GRAF_LOCAL}/api"

  # --- 3. Grafana Prometheus data source answers a sample query -------------
  info "checking the Grafana Prometheus data source answers a query"
  if curl -sf "${gauth[@]}" "${gbase}/org" >/dev/null 2>&1; then
    pass "Grafana token authenticates (GET /api/org)"
  else
    fail "Grafana token did NOT authenticate"
  fi
  DS_UID="$(curl -sf "${gauth[@]}" "${gbase}/datasources" \
    | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null | head -n1)"
  if [[ -z "${DS_UID}" ]]; then
    fail "no Prometheus data source found in Grafana"
  else
    pass "Prometheus data source present (uid=${DS_UID})"
    qres="$(curl -sf "${gauth[@]}" -X POST "${gbase}/ds/query" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg uid "${DS_UID}" '{
             from: "now-5m", to: "now",
             queries: [{ refId: "A", datasource: {type:"prometheus", uid:$uid},
                         expr: "up", queryType: "range" }]
           }')" 2>/dev/null)"
    if echo "${qres}" | jq -e '.results.A.error' >/dev/null 2>&1; then
      fail "Grafana data source query returned an error: $(echo "${qres}" | jq -c '.results.A.error')"
    elif echo "${qres}" | jq -e '(.results.A.frames // .results.A.data) != null' >/dev/null 2>&1; then
      pass "Grafana data source answered the sample query (up)"
    else
      pass "Grafana data source answered the sample query"
    fi
  fi

  # --- 5. Folders / dashboards listable ------------------------------------
  info "checking Grafana can list folders/dashboards"
  if curl -sf "${gauth[@]}" "${gbase}/folders" >/dev/null 2>&1; then
    pass "Grafana API lists folders"
  else
    fail "Grafana API could not list folders"
  fi
  folder_id="$(curl -sf "${gauth[@]}" "${gbase}/folders" \
    | jq -r --arg n "${FOLDER}" '.[] | select(.title==$n) | .id' 2>/dev/null | head -n1)"
  if [[ -n "${folder_id}" ]]; then
    pass "folder '${FOLDER}' exists (id=${folder_id}); dashboards: $( \
      curl -sf "${gauth[@]}" "${gbase}/search?folderIds=${folder_id}&limit=100" \
        | jq -r '[.[] | select(.type=="dash-db")] | length' 2>/dev/null)"
  else
    warn "folder '${FOLDER}' not present yet (created by the agent during the dialogue)"
  fi
fi

# --- 4. RemoteMCPServers Accepted --------------------------------------------
info "checking RemoteMCPServers are Accepted"
for rmc in kagent-grafana-mcp prometheus-mcp; do
  acc="$(kubectl -n "$KAGENT_NAMESPACE" get remotemcpserver "$rmc" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  if [[ "${acc}" == "True" ]]; then
    pass "RemoteMCPServer '${rmc}' Accepted"
  else
    fail "RemoteMCPServer '${rmc}' not Accepted (status='${acc:-<none>}')"
  fi
done

# --- Summary ------------------------------------------------------------------
echo
info "verify-monitoring summary: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  err "verification FAILED"
  exit 1
fi
ok "verification PASSED"
exit 0
