# ArgoCD-managed Multi-Chart Makefile for Kind development cluster
# This Makefile bootstraps ArgoCD and applies Application manifests
# Usage: make help

# Variables
CLUSTER_NAME ?= k8s-local
KIND_CONFIG ?= kind-config.yaml
ARGOCD_NAMESPACE ?= argocd
APPLICATION_DIR ?= application/kind

# Auto-discover application manifests
APP_MANIFESTS := $(shell find $(APPLICATION_DIR) -name "*.yaml" 2>/dev/null | sort)

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
	@echo "$(PURPLE)🚀 ArgoCD-managed Kind Development Cluster$(NC)"
	@echo ""
	@$(MAKE) list-apps
	@echo ""
	@echo "$(BLUE)🚀 Quick Commands:$(NC)"
	@echo "  $(GREEN)make up$(NC)                    - Bootstrap cluster with ArgoCD + deploy all apps"
	@echo "  $(GREEN)make down$(NC)                  - Destroy everything"
	@echo "  $(GREEN)make restart$(NC)               - Down + Up"
	@echo ""
	@echo "$(BLUE)🔧 ArgoCD Management:$(NC)"
	@echo "  $(GREEN)make bootstrap$(NC)             - Create cluster + install ArgoCD only"
	@echo "  $(GREEN)make deploy-apps$(NC)           - Deploy all ArgoCD Applications"
	@echo "  $(GREEN)make sync-apps$(NC)             - Sync all ArgoCD Applications"
	@echo ""
	@echo "$(BLUE)🔍 Monitoring:$(NC)"
	@echo "  $(GREEN)make status$(NC)                - Show cluster and ArgoCD status"
	@echo "  $(GREEN)make apps$(NC)                  - Show ArgoCD Applications status"
	@echo "  $(GREEN)make ui$(NC)                    - Port-forward to ArgoCD UI"
	@echo "  $(GREEN)make password$(NC)              - Get ArgoCD admin password"
	@echo ""
	@echo "$(BLUE)📋 Information:$(NC)"
	@echo "  $(GREEN)make list-apps$(NC)             - List discovered Application manifests"

.PHONY: check-tools
check-tools: ## Check if required tools are installed
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)❌ docker required$(NC)"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "$(RED)❌ kind required$(NC)"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "$(RED)❌ kubectl required$(NC)"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "$(RED)❌ helm required$(NC)"; exit 1; }
	@echo "$(GREEN)✅ All tools available$(NC)"

.PHONY: list-apps
list-apps: ## List discovered ArgoCD Application manifests
	@echo "$(CYAN)📋 Discovered Applications:$(NC)"
	@if [ -z "$(APP_MANIFESTS)" ]; then \
		echo "  $(YELLOW)No applications found in $(APPLICATION_DIR)/$(NC)"; \
		echo "  $(YELLOW)Expected: $(APPLICATION_DIR)/*.yaml$(NC)"; \
	else \
		for manifest in $(APP_MANIFESTS); do \
			app_name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
			namespace=$$(grep '^    namespace:' $$manifest 2>/dev/null | awk '{print $$2}'); \
			path=$$(grep '^    path:' $$manifest 2>/dev/null | awk '{print $$2}'); \
			printf "  $(CYAN)%-25s$(NC) -> %-20s (ns: %-15s) path: %s\n" "$$(basename $$manifest)" "$$app_name" "$$namespace" "$$path"; \
		done \
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

.PHONY: install-argocd
install-argocd: ## Install ArgoCD
	@echo "$(BLUE)📦 Installing ArgoCD...$(NC)"
	@helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	@helm repo update >/dev/null 2>&1
	@helm upgrade --install argocd argo/argo-cd \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		--wait --timeout=300s \
		--set server.service.type=NodePort \
		--set server.service.nodePortHttp=30080 \
		--set server.service.nodePortHttps=30443
	@echo "$(GREEN)✅ ArgoCD installed$(NC)"
	@echo "$(BLUE)🔗 ArgoCD will be available at: http://localhost:30080$(NC)"

.PHONY: deploy-apps
deploy-apps: ## Deploy all ArgoCD Applications
	@if [ -z "$(APP_MANIFESTS)" ]; then \
		echo "$(YELLOW)⚠️  No application manifests found in $(APPLICATION_DIR)/$(NC)"; \
		echo "$(YELLOW)💡 Create Application manifests in $(APPLICATION_DIR)/ directory$(NC)"; \
	else \
		echo "$(BLUE)📦 Deploying ArgoCD Applications...$(NC)"; \
		for manifest in $(APP_MANIFESTS); do \
			app_name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
			echo "$(BLUE)📦 Applying $$app_name from $$(basename $$manifest)...$(NC)"; \
			kubectl apply -f $$manifest; \
		done; \
		echo "$(GREEN)✅ All applications deployed$(NC)"; \
		echo "$(BLUE)🔄 ArgoCD will sync applications automatically$(NC)"; \
	fi

.PHONY: remove-apps
remove-apps: ## Remove all ArgoCD Applications
	@if [ -n "$(APP_MANIFESTS)" ]; then \
		echo "$(BLUE)🗑️  Removing ArgoCD Applications...$(NC)"; \
		for manifest in $(APP_MANIFESTS); do \
			app_name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
			echo "$(BLUE)🗑️  Removing $$app_name...$(NC)"; \
			kubectl delete -f $$manifest --ignore-not-found=true; \
		done; \
		echo "$(GREEN)✅ All applications removed$(NC)"; \
	fi

.PHONY: sync-apps
sync-apps: ## Force sync all ArgoCD Applications
	@echo "$(BLUE)🔄 Syncing all ArgoCD Applications...$(NC)"
	@for manifest in $(APP_MANIFESTS); do \
		app_name=$$(grep '^  name:' $$manifest 2>/dev/null | head -1 | awk '{print $$2}'); \
		if [ -n "$$app_name" ]; then \
			echo "$(BLUE)🔄 Syncing $$app_name...$(NC)"; \
			kubectl patch application $$app_name -n $(ARGOCD_NAMESPACE) \
				--type merge --patch '{"operation":{"sync":{"revision":"HEAD"}}}' 2>/dev/null || \
			echo "$(YELLOW)⚠️  $$app_name not found or already syncing$(NC)"; \
		fi \
	done
	@echo "$(GREEN)✅ Sync requests sent$(NC)"

.PHONY: status
status: ## Show cluster and ArgoCD status
	@echo "$(BLUE)📊 Cluster Status$(NC)"
	@kubectl cluster-info --context kind-$(CLUSTER_NAME) 2>/dev/null || echo "$(RED)❌ Cluster not running$(NC)"
	@echo ""
	@echo "$(BLUE)📦 ArgoCD Status$(NC)"
	@kubectl get pods -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "$(YELLOW)ArgoCD not installed$(NC)"
	@echo ""
	@echo "$(BLUE)🏠 Namespaces$(NC)"
	@kubectl get namespaces --no-headers 2>/dev/null | awk '{print "  " $$1}' || echo "$(RED)❌ Cannot access cluster$(NC)"

.PHONY: apps
apps: ## Show ArgoCD Applications status
	@echo "$(BLUE)📋 ArgoCD Applications$(NC)"
	@kubectl get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "$(YELLOW)No applications found$(NC)"

.PHONY: ui
ui: ## Port-forward to ArgoCD UI (localhost:8080)
	@echo "$(BLUE)🔗 Port forwarding ArgoCD UI to localhost:8080$(NC)"
	@echo "$(YELLOW)Press Ctrl+C to stop$(NC)"
	@echo "$(CYAN)💡 Login: admin / $$(make password)$(NC)"
	@kubectl port-forward svc/argocd-server -n $(ARGOCD_NAMESPACE) 8080:443

.PHONY: password
password: ## Get ArgoCD admin password
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo

.PHONY: bootstrap
bootstrap: create-cluster install-argocd ## Create cluster and install ArgoCD only
	@echo "$(GREEN)🎉 ArgoCD bootstrap completed!$(NC)"
	@echo ""
	@echo "$(BLUE)Next steps:$(NC)"
	@echo "  1. $(GREEN)make deploy-apps$(NC)        - Deploy applications via ArgoCD"
	@echo "  2. $(GREEN)make ui$(NC)                - Access ArgoCD UI"
	@echo "  3. $(GREEN)make password$(NC)          - Get admin password"
	@echo ""
	@echo "$(BLUE)ArgoCD Access:$(NC)"
	@echo "  URL: $(CYAN)http://localhost:30080$(NC) (NodePort)"
	@echo "  URL: $(CYAN)http://localhost:8080$(NC) (run 'make ui' for port-forward)"
	@echo "  User: $(CYAN)admin$(NC)"
	@echo "  Pass: $(CYAN)$$(make password 2>/dev/null || echo 'run: make password')$(NC)"

.PHONY: up
up: bootstrap deploy-apps ## Complete setup: cluster + ArgoCD + applications
	@echo "$(GREEN)🎉 Complete environment ready!$(NC)"
	@echo ""
	@echo "$(BLUE)ArgoCD Applications:$(NC)"
	@kubectl get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "$(YELLOW)No applications deployed$(NC)"
	@echo ""
	@echo "$(BLUE)Quick Access:$(NC)"
	@echo "  $(GREEN)make apps$(NC)               - Check application status"
	@echo "  $(GREEN)make ui$(NC)                 - Access ArgoCD UI"
	@echo "  $(GREEN)make status$(NC)             - Overall cluster status"

.PHONY: down
down: remove-apps delete-cluster ## Destroy everything
	@echo "$(GREEN)🧹 Environment cleaned up$(NC)"

.PHONY: restart
restart: down up ## Restart everything
	@echo "$(GREEN)🔄 Environment restarted$(NC)"
