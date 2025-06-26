# FluxCD-managed Multi-Component Makefile for Kubernetes clusters
# Supports Kustomize (base/overlays) and Helm (environments) directory structures
# Usage: make help

# Variables
CLUSTER_NAME ?= k8s-local
KIND_CONFIG ?= kind-config.yaml
FLUXCD_NAMESPACE ?= flux-system
ENVIRONMENT ?= kind

# Auto-discover components with standard directory structures
# Supports: overlays/{environment} (Kustomize) and {environment} (Helm)
COMPONENTS := $(shell \
	for dir in */; do \
		component=$$(basename "$$dir"); \
		if [ -d "$$component/overlays/$(ENVIRONMENT)" ] || [ -d "$$component/$(ENVIRONMENT)" ]; then \
			echo "$$component"; \
		fi; \
	done | sort)

# Auto-discover flux manifests from all components
# Search in overlays/{environment} (Kustomize) or {environment} (Helm)
FLUX_MANIFESTS := $(shell \
	for component in $(COMPONENTS); do \
		if [ -d "$$component/overlays/$(ENVIRONMENT)" ]; then \
			find "$$component/overlays/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null; \
		elif [ -d "$$component/$(ENVIRONMENT)" ]; then \
			find "$$component/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null; \
		fi; \
	done | sort)

# Colors
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[0;33m
BLUE = \033[0;34m
PURPLE = \033[0;35m
CYAN = \033[0;36m
NC = \033[0m

.PHONY: help
help: ## Show this help message
	@echo "$(PURPLE)🚀 FluxCD-managed Multi-Component Kubernetes Cluster$(NC)"
	@echo ""
	@echo "$(BLUE)🔧 Environment: $(ENVIRONMENT)$(NC)"
	@if [ -n "$(COMPONENTS)" ]; then \
		echo "$(BLUE)📦 Components: $(COMPONENTS)$(NC)"; \
	else \
		echo "$(YELLOW)⚠️  No components found for environment '$(ENVIRONMENT)'$(NC)"; \
	fi
	@echo ""
	@$(MAKE) list-manifests
	@echo ""
	@echo "$(BLUE)🚀 Quick Commands:$(NC)"
	@echo "  $(GREEN)make up$(NC)                    - Bootstrap cluster with FluxCD + deploy all manifests"
	@echo "  $(GREEN)make down$(NC)                  - Destroy everything"
	@echo "  $(GREEN)make restart$(NC)               - Down + Up"
	@echo ""
	@echo "$(BLUE)🔧 FluxCD Management:$(NC)"
	@echo "  $(GREEN)make bootstrap$(NC)             - Create cluster + install FluxCD only"
	@echo "  $(GREEN)make deploy-manifests$(NC)      - Deploy all Flux manifests for current environment"
	@echo "  $(GREEN)make reconcile$(NC)             - Force reconcile all Flux resources"
	@echo "  $(GREEN)make reconcile-component COMPONENT=<name>$(NC) - Reconcile specific component"
	@echo ""
	@echo "$(BLUE)🔍 Monitoring:$(NC)"
	@echo "  $(GREEN)make status$(NC)                - Show cluster and FluxCD status"
	@echo "  $(GREEN)make resources$(NC)             - Show Flux resources status"
	@echo ""
	@echo "$(BLUE)📋 Information:$(NC)"
	@echo "  $(GREEN)make list-manifests$(NC)        - List discovered Flux manifests"
	@echo ""
	@echo "$(BLUE)🔧 Environment Override:$(NC)"
	@echo "  $(GREEN)make <command> ENVIRONMENT=staging$(NC)  - Run command for staging environment"
	@echo "  $(GREEN)make <command> ENVIRONMENT=production$(NC) - Run command for production environment"

.PHONY: check-tools
check-tools: ## Check if required tools are installed
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)❌ docker required$(NC)"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "$(RED)❌ kind required$(NC)"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "$(RED)❌ kubectl required$(NC)"; exit 1; }
	@command -v flux >/dev/null 2>&1 || { echo "$(RED)❌ flux CLI required$(NC)"; exit 1; }
	@echo "$(GREEN)✅ All tools available$(NC)"

.PHONY: list-manifests
list-manifests: ## List discovered Flux manifests
	@echo "$(CYAN)📋 Discovered Manifests (Environment: $(ENVIRONMENT)):$(NC)"
	@found_any=false; \
	for component in $(COMPONENTS); do \
		if [ -d "$$component/overlays/$(ENVIRONMENT)" ]; then \
			manifests=$$(find "$$component/overlays/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			env_path="overlays/$(ENVIRONMENT)"; \
		elif [ -d "$$component/$(ENVIRONMENT)" ]; then \
			manifests=$$(find "$$component/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			env_path="$(ENVIRONMENT)"; \
		fi; \
		if [ -n "$$manifests" ]; then \
			echo "  $(PURPLE)$$component/$$env_path:$(NC)"; \
			found_any=true; \
			for manifest in $$manifests; do \
				kind=$$(grep '^kind:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
				name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
				namespace=$$(grep '^  namespace:' $$manifest 2>/dev/null | awk '{print $$2}'); \
				printf "    $(CYAN)%-20s$(NC) -> %-15s/%-20s (ns: %-15s)\n" "$$(basename $$manifest)" "$$kind" "$$name" "$$namespace"; \
			done; \
			echo ""; \
		fi; \
	done; \
	if [ "$$found_any" = "false" ]; then \
		echo "  $(YELLOW)No manifests found for environment '$(ENVIRONMENT)'$(NC)"; \
		echo "  $(YELLOW)Expected structures:$(NC)"; \
		echo "  $(YELLOW)  - Kustomize: {component}/overlays/$(ENVIRONMENT)/*.yaml$(NC)"; \
		echo "  $(YELLOW)  - Helm: {component}/$(ENVIRONMENT)/*.yaml$(NC)"; \
		echo "  $(YELLOW)Available components: $(COMPONENTS)$(NC)"; \
	fi

.PHONY: create-cluster
create-cluster: check-tools ## Create Kind cluster
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "$(YELLOW)⚠️  Cluster $(CLUSTER_NAME) exists$(NC)"; \
	else \
		echo "$(BLUE)🚀 Creating cluster $(CLUSTER_NAME)...$(NC)"; \
		if [ ! -f $(KIND_CONFIG) ]; then \
			echo "Creating $(KIND_CONFIG)..."; \
			printf '%s\n' \
				'kind: Cluster' \
				'apiVersion: kind.x-k8s.io/v1alpha4' \
				'nodes:' \
				'- role: control-plane' \
				'  kubeadmConfigPatches:' \
				'  - |' \
				'    kind: InitConfiguration' \
				'    nodeRegistration:' \
				'      kubeletExtraArgs:' \
				'        node-labels: "ingress-ready=true"' \
				'  extraPortMappings:' \
				'  - containerPort: 80' \
				'    hostPort: 80' \
				'    protocol: TCP' \
				'  - containerPort: 443' \
				'    hostPort: 443' \
				'    protocol: TCP' \
				> $(KIND_CONFIG); \
		fi; \
		kind create cluster --config=$(KIND_CONFIG) --name=$(CLUSTER_NAME); \
		echo "$(GREEN)✅ Cluster ready$(NC)"; \
	fi

.PHONY: delete-cluster
delete-cluster: ## Delete Kind cluster
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "$(BLUE)🗑️  Deleting cluster $(CLUSTER_NAME)...$(NC)"; \
		kind delete cluster --name=$(CLUSTER_NAME); \
		echo "$(GREEN)✅ Cluster deleted$(NC)"; \
	else \
		echo "$(YELLOW)⚠️  Cluster $(CLUSTER_NAME) not found$(NC)"; \
	fi

.PHONY: install-flux
install-flux: ## Install FluxCD
	@echo "$(BLUE)📦 Installing FluxCD...$(NC)"
	@flux check --pre >/dev/null 2>&1 || { echo "$(RED)❌ FluxCD pre-check failed$(NC)"; exit 1; }
	@flux install --namespace=$(FLUXCD_NAMESPACE) --network-policy=false --components-extra=image-reflector-controller,image-automation-controller
	@echo "$(GREEN)✅ FluxCD installed$(NC)"

.PHONY: deploy-manifests
deploy-manifests: ## Deploy all Flux manifests
	@if [ -z "$(COMPONENTS)" ]; then \
		echo "$(YELLOW)⚠️  No components found for environment '$(ENVIRONMENT)'$(NC)"; \
		echo "$(YELLOW)💡 Create component directories with standard structures:$(NC)"; \
		echo "$(YELLOW)💡 Kustomize: component/overlays/$(ENVIRONMENT)/$(NC)"; \
		echo "$(YELLOW)💡 Helm: component/$(ENVIRONMENT)/$(NC)"; \
	elif [ -z "$(FLUX_MANIFESTS)" ]; then \
		echo "$(YELLOW)⚠️  No manifests found in any component for environment '$(ENVIRONMENT)'$(NC)"; \
		echo "$(YELLOW)💡 Available components: $(COMPONENTS)$(NC)"; \
	else \
		echo "$(BLUE)📦 Deploying Flux manifests for environment '$(ENVIRONMENT)'...$(NC)"; \
		for component in $(COMPONENTS); do \
			if [ -d "$$component/overlays/$(ENVIRONMENT)" ]; then \
				component_manifests=$$(find "$$component/overlays/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			elif [ -d "$$component/$(ENVIRONMENT)" ]; then \
				component_manifests=$$(find "$$component/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			fi; \
			if [ -n "$$component_manifests" ]; then \
				echo "$(PURPLE)📦 Component: $$component$(NC)"; \
				for manifest in $$component_manifests; do \
					kind=$$(grep '^kind:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
					name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
					echo "$(BLUE)  📦 Applying $$kind/$$name from $$(basename $$manifest)...$(NC)"; \
					kubectl apply -f $$manifest; \
				done; \
			fi; \
		done; \
		echo "$(GREEN)✅ All manifests deployed$(NC)"; \
		echo "$(BLUE)🔄 FluxCD will reconcile resources automatically$(NC)"; \
	fi

.PHONY: remove-manifests
remove-manifests: ## Remove all Flux manifests
	@if [ -z "$(COMPONENTS)" ]; then \
		echo "$(YELLOW)⚠️  No components found for environment '$(ENVIRONMENT)'$(NC)"; \
	elif [ -z "$(FLUX_MANIFESTS)" ]; then \
		echo "$(YELLOW)⚠️  No manifests found in any component for environment '$(ENVIRONMENT)'$(NC)"; \
		echo "$(YELLOW)💡 Available components: $(COMPONENTS)$(NC)"; \
	else \
		echo "$(BLUE)🗑️  Removing Flux manifests for environment '$(ENVIRONMENT)'...$(NC)"; \
		for component in $(COMPONENTS); do \
			if [ -d "$$component/overlays/$(ENVIRONMENT)" ]; then \
				component_manifests=$$(find "$$component/overlays/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			elif [ -d "$$component/$(ENVIRONMENT)" ]; then \
				component_manifests=$$(find "$$component/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
			fi; \
			if [ -n "$$component_manifests" ]; then \
				echo "$(PURPLE)🗑️  Component: $$component$(NC)"; \
				for manifest in $$component_manifests; do \
					kind=$$(grep '^kind:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
					name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
					echo "$(BLUE)  🗑️  Removing $$kind/$$name from $$(basename $$manifest)...$(NC)"; \
					kubectl delete -f $$manifest --ignore-not-found=true; \
				done; \
			fi; \
		done; \
		echo "$(GREEN)✅ All manifests removed$(NC)"; \
	fi

.PHONY: reconcile
reconcile: ## Force reconcile all Flux resources for current environment
	@echo "$(BLUE)🔄 Reconciling all Flux resources for environment '$(ENVIRONMENT)'...$(NC)"
	@if [ -z "$(COMPONENTS)" ]; then \
		echo "$(YELLOW)⚠️  No components found for environment '$(ENVIRONMENT)'$(NC)"; \
	else \
		echo "$(BLUE)🔄 Available components: $(COMPONENTS)$(NC)"; \
		echo "$(BLUE)🔄 Reconciling GitRepositories...$(NC)"; \
		flux reconcile source git --all-namespaces 2>/dev/null || echo "$(YELLOW)⚠️  No GitRepositories found$(NC)"; \
		echo "$(BLUE)🔄 Reconciling HelmRepositories...$(NC)"; \
		flux reconcile source helm --all-namespaces 2>/dev/null || echo "$(YELLOW)⚠️  No HelmRepositories found$(NC)"; \
		echo "$(BLUE)🔄 Reconciling Kustomizations...$(NC)"; \
		flux reconcile kustomization --all-namespaces 2>/dev/null || echo "$(YELLOW)⚠️  No Kustomizations found$(NC)"; \
		echo "$(BLUE)🔄 Reconciling HelmReleases...$(NC)"; \
		flux reconcile helmrelease --all-namespaces 2>/dev/null || echo "$(YELLOW)⚠️  No HelmReleases found$(NC)"; \
		echo "$(GREEN)✅ Reconcile requests sent$(NC)"; \
	fi

.PHONY: reconcile-component
reconcile-component: ## Force reconcile specific component (usage: make reconcile-component COMPONENT=fluxcd)
	@if [ -z "$(COMPONENT)" ]; then \
		echo "$(RED)❌ COMPONENT parameter required$(NC)"; \
		echo "$(YELLOW)💡 Usage: make reconcile-component COMPONENT=fluxcd$(NC)"; \
		echo "$(YELLOW)💡 Available components: $(COMPONENTS)$(NC)"; \
		exit 1; \
	elif ! echo "$(COMPONENTS)" | grep -q "$(COMPONENT)"; then \
		echo "$(RED)❌ Component '$(COMPONENT)' not found$(NC)"; \
		echo "$(YELLOW)💡 Available components: $(COMPONENTS)$(NC)"; \
		exit 1; \
	else \
		echo "$(BLUE)🔄 Reconciling component '$(COMPONENT)' for environment '$(ENVIRONMENT)'...$(NC)"; \
		if [ -d "$(COMPONENT)/overlays/$(ENVIRONMENT)" ]; then \
			component_manifests=$$(find "$(COMPONENT)/overlays/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
		elif [ -d "$(COMPONENT)/$(ENVIRONMENT)" ]; then \
			component_manifests=$$(find "$(COMPONENT)/$(ENVIRONMENT)" -name "*.yaml" 2>/dev/null | sort); \
		fi; \
		if [ -n "$$component_manifests" ]; then \
			for manifest in $$component_manifests; do \
				kind=$$(grep '^kind:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
				name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
				namespace=$$(grep '^  namespace:' $$manifest 2>/dev/null | awk '{print $$2}' || echo "default"); \
				case "$$kind" in \
					"GitRepository") flux reconcile source git "$$name" -n "$$namespace" 2>/dev/null || echo "$(YELLOW)⚠️  Failed to reconcile GitRepository $$name$(NC)";; \
					"HelmRepository") flux reconcile source helm "$$name" -n "$$namespace" 2>/dev/null || echo "$(YELLOW)⚠️  Failed to reconcile HelmRepository $$name$(NC)";; \
					"Kustomization") flux reconcile kustomization "$$name" -n "$$namespace" 2>/dev/null || echo "$(YELLOW)⚠️  Failed to reconcile Kustomization $$name$(NC)";; \
					"HelmRelease") flux reconcile helmrelease "$$name" -n "$$namespace" 2>/dev/null || echo "$(YELLOW)⚠️  Failed to reconcile HelmRelease $$name$(NC)";; \
				esac; \
			done; \
			echo "$(GREEN)✅ Component '$(COMPONENT)' reconcile requests sent$(NC)"; \
		else \
			echo "$(YELLOW)⚠️  No manifests found for component '$(COMPONENT)'$(NC)"; \
		fi; \
	fi

.PHONY: status
status: ## Show cluster and FluxCD status
	@echo "$(BLUE)📊 Cluster Status$(NC)"
	@kubectl cluster-info --context kind-$(CLUSTER_NAME) 2>/dev/null || echo "$(RED)❌ Cluster not running$(NC)"
	@echo ""
	@echo "$(BLUE)📦 FluxCD Status$(NC)"
	@kubectl get pods -n $(FLUXCD_NAMESPACE) 2>/dev/null || echo "$(YELLOW)FluxCD not installed$(NC)"
	@echo ""
	@echo "$(BLUE)🏠 Namespaces$(NC)"
	@kubectl get namespaces --no-headers 2>/dev/null | awk '{print "  " $$1}' || echo "$(RED)❌ Cannot access cluster$(NC)"

.PHONY: resources
resources: ## Show Flux resources status
	@echo "$(BLUE)📋 Flux Resources$(NC)"
	@echo "$(CYAN)GitRepositories:$(NC)"
	@kubectl get gitrepositories --all-namespaces 2>/dev/null || echo "  $(YELLOW)No GitRepositories found$(NC)"
	@echo ""
	@echo "$(CYAN)HelmRepositories:$(NC)"
	@kubectl get helmrepositories --all-namespaces 2>/dev/null || echo "  $(YELLOW)No HelmRepositories found$(NC)"
	@echo ""
	@echo "$(CYAN)Kustomizations:$(NC)"
	@kubectl get kustomizations --all-namespaces 2>/dev/null || echo "  $(YELLOW)No Kustomizations found$(NC)"
	@echo ""
	@echo "$(CYAN)HelmReleases:$(NC)"
	@kubectl get helmreleases --all-namespaces 2>/dev/null || echo "  $(YELLOW)No HelmReleases found$(NC)"


.PHONY: bootstrap
bootstrap: create-cluster install-flux ## Create cluster and install FluxCD only
	@echo "$(GREEN)🎉 FluxCD bootstrap completed!$(NC)"
	@echo ""
	@echo "$(BLUE)Next steps:$(NC)"
	@echo "  1. $(GREEN)make deploy-manifests$(NC)   - Deploy Flux manifests"
	@echo "  2. $(GREEN)make resources$(NC)          - Check Flux resources status"
	@echo "  3. $(GREEN)make reconcile$(NC)          - Force reconciliation"

.PHONY: up
up: bootstrap deploy-manifests ## Complete setup: cluster + FluxCD + manifests
	@echo "$(GREEN)🎉 Complete environment ready!$(NC)"
	@echo ""
	@echo "$(BLUE)Flux Resources:$(NC)"
	@flux get all --all-namespaces 2>/dev/null || echo "$(YELLOW)No resources deployed$(NC)"
	@echo ""
	@echo "$(BLUE)Quick Access:$(NC)"
	@echo "  $(GREEN)make resources$(NC)          - Check resources status"
	@echo "  $(GREEN)make reconcile$(NC)          - Force reconciliation"
	@echo "  $(GREEN)make status$(NC)             - Overall cluster status"

.PHONY: down
down: remove-manifests delete-cluster ## Destroy everything
	@echo "$(GREEN)🧹 Environment cleaned up$(NC)"

.PHONY: restart
restart: down up ## Restart everything
	@echo "$(GREEN)🔄 Environment restarted$(NC)"
