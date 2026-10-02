#!/usr/bin/env bash
# Verify (and, where possible, install) the toolchain required by this tutorial.
#
# Missing pieces are installed non-destructively:
#   - kubectl-ate  -> the Agent Substrate kubectl plugin (required by the
#                     substrate identity bootstrap)
#   - kagent       -> the kagent CLI (used to create/invoke agents)
#
# Everything else is only *checked*; install it with your package manager if
# it is absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SUDO=""
[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

# --- static checks ------------------------------------------------------------
info "checking required tools..."
require_cmd kind kubectl helm jq openssl docker
# Note: the host `ollama` CLI is NOT required — Ollama runs inside the cluster.

# --- kubectl-ate plugin -------------------------------------------------------
ate_version="$(kubectl ate --version 2>/dev/null | awk '{print $3}' || true)"
if [[ "$ate_version" == "v${SUBSTRATE_VERSION}" ]]; then
  ok "kubectl-ate plugin is installed (${ate_version})"
else
  warn "kubectl-ate plugin is '${ate_version:-missing}'; installing v${SUBSTRATE_VERSION}..."
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
  url="https://github.com/kagent-dev/substrate/releases/download/v${SUBSTRATE_VERSION}/kubectl-ate-${os}-${arch}"
  info "downloading ${url}"
  curl -fsSL -o /tmp/kubectl-ate "$url"
  chmod +x /tmp/kubectl-ate
  $SUDO mv /tmp/kubectl-ate /usr/local/bin/kubectl-ate
  ok "kubectl-ate installed to /usr/local/bin/kubectl-ate"
  kubectl ate --help >/dev/null 2>&1 || { err "kubectl-ate install failed"; exit 1; }
fi

# --- kagent CLI ---------------------------------------------------------------
kagent_version="$(kagent version 2>/dev/null | jq -r '.kagent_version' 2>/dev/null || true)"
if [[ "$kagent_version" == "${KAGENT_VERSION}" ]]; then
  ok "kagent CLI is installed (${kagent_version})"
else
  warn "kagent CLI is '${kagent_version:-missing}'; installing v${KAGENT_VERSION}..."
  # Pin the CLI to the same version as the controller: the kagent CLI command
  # surface changed between releases, so a mismatched CLI fails with
  # "unknown command" errors.
  curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash -s -- --version "v${KAGENT_VERSION}"
  ok "kagent CLI installed"
fi

# --- final summary ------------------------------------------------------------
echo
ok "all prerequisites satisfied."
echo
echo "  kind         $(kind version 2>/dev/null | head -1 || echo '?')"
echo "  kubectl      $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | cut -d'"' -f2 || echo '?')"
echo "  helm         $(helm version --short 2>/dev/null || echo '?')"
echo "  ollama       $(ollama --version 2>/dev/null || echo '?')"
echo "  kagent       $(kagent version 2>/dev/null | head -1 || echo '?')"
echo "  kubectl-ate  v${SUBSTRATE_VERSION}"
