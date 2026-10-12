# kind + kagent + local Ollama tutorial
#
# Configuration is read from the environment; the defaults below match
# scripts/lib.sh. Override inline, e.g.:
#
#   make up OLLAMA_MODEL=qwen3:4b
#   make chat Q="What is a ReadinessProbe?" OLLAMA_MODEL=qwen3:8b

CLUSTER_NAME  ?= kagent
OLLAMA_MODEL  ?= qwen3:8b
Q             ?= What is the difference between a Deployment and a StatefulSet?

export CLUSTER_NAME
export OLLAMA_MODEL

.PHONY: help prereqs up verify-monitoring down chat ui logs status clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

prereqs: ## Check / install the toolchain (kubectl-ate, kagent CLI)
	./scripts/prerequisites.sh

up: ## Bring up the full stack (kind + substrate + kagent + ollama + monitoring + Boutique)
	./scripts/up.sh

verify-monitoring: ## Health-check the monitoring plane after `make up` (exit 0 = OK)
	./scripts/verify-monitoring.sh

chat: ## Chat with the k8s-expert agent (Q="your question")
	./scripts/chat.sh "$(Q)"

ui: ## Port-forward the kagent web UI to http://localhost:8082
	./scripts/ui.sh

status: ## Show the state of the whole stack
	./scripts/status.sh

logs: ## Tail kagent controller + ollama logs
	kubectl -n kagent logs -l app.kubernetes.io/component=controller -f --tail=50

down: ## Delete the kind cluster (asks for confirmation)
	./scripts/down.sh

clean: ## Delete the kind cluster without confirmation
	./scripts/down.sh --yes
