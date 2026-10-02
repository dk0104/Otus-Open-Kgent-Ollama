#!/usr/bin/env bash
# Shared configuration and helpers for the kind + kagent + Ollama tutorial.
#
# Every script in this repository sources this file. Version pins and defaults
# live here so there is a single source of truth.

set -euo pipefail

# --- Version pins (verified against the kagent / substrate releases) ----------
export KAGENT_VERSION="${KAGENT_VERSION:-1.0.0-alpha3}"
export SUBSTRATE_VERSION="${SUBSTRATE_VERSION:-0.2.0-beta5}"

# kagent's native runtime image (golang-adk), pinned by digest for the version above.
export KAGENT_RUNTIME_IMAGE="${KAGENT_RUNTIME_IMAGE:-ghcr.io/kagent-dev/kagent/golang-adk@sha256:699c7a36daa0050d5954f42ad3b614690d825664cf64ffe8871dbe20dc68464e}"

# --- Cluster / namespace defaults ---------------------------------------------
export CLUSTER_NAME="${CLUSTER_NAME:-kagent}"
export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.37.0}"
export KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
export ATE_NAMESPACE="${ATE_NAMESPACE:-ate-system}"
export OLLAMA_NAMESPACE="${OLLAMA_NAMESPACE:-ollama}"

# --- Ollama settings ----------------------------------------------------------
# A model with solid function/tool-calling support is required, because kagent
# agents call tools. qwen3:8b is the recommended default; qwen3:4b / llama3.2
# are lighter alternatives.
export OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:8b}"
export OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"

# --- OCI chart locations ------------------------------------------------------
export SUBSTRATE_CRDS_CHART="oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds"
export SUBSTRATE_CHART="oci://ghcr.io/kagent-dev/substrate/helm/substrate"
export KAGENT_CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
export KAGENT_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"

# --- Paths --------------------------------------------------------------------
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Logging helpers ----------------------------------------------------------
c_red='\033[0;31m'; c_green='\033[0;32m'; c_yellow='\033[0;33m'; c_cyan='\033[0;36m'; c_reset='\033[0m'
info() { printf "${c_cyan}[info]${c_reset}  %s\n" "$*"; }
ok()   { printf "${c_green}[ ok ]${c_reset}  %s\n" "$*"; }
warn() { printf "${c_yellow}[warn]${c_reset}  %s\n" "$*"; }
err()  { printf "${c_red}[ err]${c_reset}  %s\n" "$*" >&2; }
run()  { info "++ $*"; "$@"; }

require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "missing required tool(s): ${missing[*]}"
    err "run: make prereqs"
    exit 1
  fi
}

# Verify the kubectl-ate plugin is available (it is a kubectl plugin, not a
# standalone binary on PATH under a distinct name).
require_ate() {
  if ! kubectl ate --help >/dev/null 2>&1; then
    err "kubectl-ate plugin is missing (kubectl ate --help failed)"
    err "run: make prereqs"
    exit 1
  fi
}
