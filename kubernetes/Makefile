# Variables
CLUSTER_NAME ?= k8s-local
ENV ?= k3d

# Colors
GREEN = \033[0;32m
BLUE = \033[0;34m
YELLOW = \033[0;33m
RED = \033[0;31m
NC = \033[0m

.PHONY: help
help: ## Show help
	@echo "$(BLUE)🚀 Kubernetes Platform Setup$(NC)"
	@echo ""
	@echo "$(BLUE)Phase 1: Foundation Setup$(NC)"
	@echo "make phase1              - Complete Phase 1"
	@echo "make cluster-create      - Create k3d cluster"
	@echo "make gateway-install     - Install Gateway API CRDs"
	@echo "make cilium-install      - Install Cilium"
	@echo "make coredns-update      - Fix CoreDNS configuration"
	@echo "make status              - Check cluster status"
	@echo ""
	@echo "$(BLUE)Phase 2: FluxCD Installation$(NC)"
	@echo "make phase2        - Complete Phase 2"
	@echo "make flux-install  - Install FluxCD"
	@echo "make flux-status   - Check FluxCD status"
	@echo ""
	@echo "$(BLUE)Phase 3: Infrastructure Auto-Bootstrap$(NC)"
	@echo "make phase3        - Complete Phase 3"
	@echo "- Auto-discovers and installs all infrastructure components"
	@echo "- Includes: Gitea, Prometheus, OpenTelemetry, etc."
	@echo ""
	@echo "$(BLUE)Phase 4: GitOps Complete Migration$(NC)"
	@echo "make phase4        - Complete Phase 4"
	@echo ""
	@echo "$(BLUE)Individual targets:$(NC)"
	@echo "make gitops-setup    - Setup FluxCD GitOps management"
	@echo "make gitops-status   - Check GitOps status"
	@echo "make gitops-enable   - Enable GitOps for all components"
	@echo "make hydrate         - Hydrate manifests from Helmfile"

##########################
# Phase 0: Hydrate Manifests
##########################

.PHONY: hydrate
hydrate: ## Hydrate manifests (usage: make hydrate ENV=production)
	@echo "$(BLUE)💧 Hydrating manifests for $(ENV)...$(NC)"
	@rm -rf manifests/$(ENV)/*
	@mkdir -p manifests/$(ENV)
	@echo "$(BLUE)💧 Hydrating namespaces...$(NC)"
	@find components -name namespace.yaml -print0 | xargs -0 -I{} sh -c 'echo "---"; cat {}' > manifests/$(ENV)/00-namespaces.yaml
	@echo "$(BLUE)💧 Hydrating helmfile components...$(NC)"
	@echo "resources:" > manifests/$(ENV)/kustomization.yaml
	@helmfile -e $(ENV) list | awk 'NR>1 {print $$1}' | while read release; do \
		echo "Hydrating $$release..."; \
		component=$$(find components -name helmfile.yaml | grep "/$(ENV)/helmfile.yaml" | xargs grep -l "name: $$release" | head -1 | cut -d'/' -f2); \
		helmfile -e $(ENV) -l name=$$release template --include-crds --skip-tests > manifests/$(ENV)/$$release.yaml; \
		if [ -n "$$component" ] && [ -d "components/$$component/$(ENV)/kustomization" ]; then \
			echo "  + Adding overlay resources from $$component..."; \
			echo "---" >> manifests/$(ENV)/$$release.yaml; \
			kustomize build components/$$component/$(ENV)/kustomization >> manifests/$(ENV)/$$release.yaml; \
		fi; \
		echo "- $$release.yaml" >> manifests/$(ENV)/kustomization.yaml; \
	done
	@echo "- 00-namespaces.yaml" >> manifests/$(ENV)/kustomization.yaml
	@echo "$(GREEN)✅ Manifests hydrated (Flat Files)$(NC)"

##########################
# Phase 1: Foundation Setup
##########################

.PHONY: cluster-create
cluster-create: ## Create k3d cluster
	@echo "$(BLUE)🚀 Creating k3d cluster...$(NC)"
	@if k3d cluster list 2>/dev/null | grep -q "^$(CLUSTER_NAME)"; then \
		echo "$(YELLOW)⚠️  Cluster already exists$(NC)"; \
	else \
		export K3D_FIX_DNS=1 && \
		export K3D_FIX_MOUNTS=1 && \
		k3d cluster create $(CLUSTER_NAME) \
			--port "80:80@loadbalancer" \
			--port "443:443@loadbalancer" \
			--k3s-arg "--disable=traefik,metrics-server@server:*" \
			--k3s-arg "--disable-network-policy@server:*" \
			--k3s-arg "--flannel-backend=none@server:*" \
			--k3s-arg "--disable-kube-proxy@server:*" \
			--k3s-arg "--resolv-conf=/etc/resolv.conf@server:*"; \
		echo "$(GREEN)✅ Cluster created$(NC)"; \
	fi

.PHONY: gateway-install
gateway-install: ## Install Gateway API CRDs
	@echo "$(BLUE)📦 Installing Gateway API CRDs...$(NC)"
	@kubectl apply -k components/gateway-api/k3d/kustomization >/dev/null
	@echo "$(BLUE)⏳ Waiting for CRDs to be registered...$(NC)"
	@kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=60s >/dev/null
	@echo "$(GREEN)✅ Gateway API CRDs installed$(NC)"

.PHONY: cilium-install
cilium-install: ## Install Cilium via Helmfile
	@echo "$(BLUE)📦 Installing Cilium via Helmfile...$(NC)"
	@if kubectl get ds cilium -n kube-system >/dev/null 2>&1; then \
    echo "$(YELLOW)⚠️  Cilium already installed$(NC)"; \
	else \
		kubectl apply -f manifests/k3d/cilium.yaml; \
		echo "$(BLUE)⏳ Waiting for Cilium to be ready...$(NC)"; \
		kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cilium-operator -n kube-system --timeout=300s >/dev/null; \
		kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s >/dev/null; \
		echo "$(GREEN)✅ Cilium installed via Manifests$(NC)"; \
	fi

.PHONY: coredns-update
coredns-update: ## Fix CoreDNS after k3s stabilization
	@echo "$(BLUE)⏳ Waiting for k3s initialization to complete...$(NC)"
	@kubectl wait --for=condition=ready node --all --timeout=300s >/dev/null
	@sleep 60
	@echo "$(BLUE)🔧 Applying CoreDNS patch (after k3s stabilization)...$(NC)"
	@kubectl apply -k components/coredns/k3d/kustomization >/dev/null
	@kubectl rollout restart deployment/coredns -n kube-system >/dev/null
	@kubectl rollout status deployment/coredns -n kube-system --timeout=300s >/dev/null
	@echo "$(BLUE)🧪 Testing DNS resolution...$(NC)"
	@if kubectl run dns-test --image=busybox --restart=Never --command -- sh -c "nslookup google.com" >/dev/null 2>&1; then \
		kubectl wait --for=condition=ready pod dns-test --timeout=30s >/dev/null 2>&1; \
		echo "$(GREEN)✅ DNS resolution working$(NC)"; \
		kubectl delete pod dns-test >/dev/null 2>&1 || true; \
	else \
		echo "$(RED)❌ DNS resolution failed$(NC)"; \
		kubectl delete pod dns-test >/dev/null 2>&1 || true; \
		exit 1; \
	fi

.PHONY: status
status: ## Check cluster status
	@echo "$(BLUE)📊 Cluster Status$(NC)"
	@kubectl get nodes
	@echo ""
	@kubectl get pods -n kube-system

#######################################
# Phase 2: FluxCD Installation
#######################################

.PHONY: flux-install
flux-install: ## Install FluxCD
	@echo "$(BLUE)📦 Installing FluxCD...$(NC)"
	@if kubectl get namespace flux-system >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  Already installed$(NC)"; \
	else \
		flux install --namespace=flux-system --components-extra=image-reflector-controller,image-automation-controller >/dev/null; \
		echo "$(GREEN)✅ FluxCD installed$(NC)"; \
	fi
	@echo "$(BLUE)⏳ Waiting for FluxCD to be ready...$(NC)"
	@kubectl wait --for=condition=ready pod -l app=source-controller -n flux-system --timeout=300s >/dev/null
	@echo "$(GREEN)✅ FluxCD is ready$(NC)"

.PHONY: flux-status
flux-status: ## Check FluxCD status
	@echo "$(BLUE)📊 FluxCD Status$(NC)"
	@kubectl get pods -n flux-system
	@echo ""
	@flux get all -A 2>/dev/null || echo "$(YELLOW)No resources found$(NC)"

#######################################
# Phase 4: GitOps Complete Migration
#######################################

.PHONY: gitops-setup
gitops-setup: ## Setup FluxCD GitOps management
	@echo "$(BLUE)🔧 Setting up FluxCD GitOps...$(NC)"
	@echo "$(BLUE)Creating FluxCD resources from clusters/k3d/flux-system...$(NC)"
	@kubectl apply -k clusters/k3d/flux-system || echo "$(YELLOW)⚠️  Push code to repository first$(NC)"
	@echo "$(GREEN)✅ GitOps setup completed$(NC)"

.PHONY: gitops-enable
gitops-enable: ## Enable GitOps management for all components
	@echo "$(BLUE)🔄 Enabling GitOps for all infrastructure components...$(NC)"
	@kubectl apply -k clusters/k3d >/dev/null || echo "$(YELLOW)⚠️  GitOps migration failed$(NC)"
	@echo "$(GREEN)✅ GitOps enabled - FluxCD now managing all components$(NC)"

.PHONY: gitops-status
gitops-status: ## Check GitOps status
	@echo "$(BLUE)📊 GitOps Status$(NC)"
	@flux get sources git -A || echo "$(YELLOW)No Git sources found$(NC)"
	@flux get kustomizations -A || echo "$(YELLOW)No Kustomizations found$(NC)"

###########################
# Complete Phases
###########################

## Foundation Setup
.PHONY: phase1
phase1: cluster-create gateway-install cilium-install coredns-update status ## Complete Phase 1
	@echo "$(GREEN)🎉 Phase 1 Complete!$(NC)"

## FluxCD Installation
.PHONY: phase2
phase2:  flux-install flux-status
	@echo "$(GREEN)🎉 Phase 2 Complete!$(NC)"

## Infrastructure Auto-Bootstrap
.PHONY: phase3
phase3:
	@echo "$(BLUE)🏗️ Applying hydrated manifests...$(NC)"
	@kubectl apply -f manifests/k3d/00-namespaces.yaml
	@echo "$(BLUE)⏳ Waiting for namespaces...$(NC)"
	@sleep 2
	@echo "$(BLUE)Applying CRD-containing stacks (allow failing once for CRDs)...$(NC)"
	@kubectl apply --server-side --force-conflicts -f manifests/k3d/kube-prometheus-stack.yaml >/dev/null 2>&1 || true
	@echo "$(BLUE)⏳ Waiting for CRDs to register...$(NC)"
	@sleep 15
	@echo "$(BLUE)Applying all manifests...$(NC)"
	@kubectl apply --server-side --force-conflicts -k manifests/k3d >/dev/null
	@echo "$(GREEN)✅ All infrastructure components installed via manifests$(NC)"
	@echo "$(GREEN)🎉 Phase 3 Complete!$(NC)"
	@echo "$(BLUE)💡 Ready for GitOps configuration (Phase 4)$(NC)"

## GitOps Migration
.PHONY: phase4
phase4: gitops-setup gitops-enable gitops-status
	@echo "$(GREEN)🎉 Phase 4 Complete!$(NC)"
	@echo "$(BLUE)🔄 Full GitOps management enabled$(NC)"
	@echo "$(BLUE)💡 All infrastructure now managed by FluxCD from Git repository$(NC)"

##########################
# Complete All Phases
##########################
.PHONY: up
up: hydrate phase1 phase2 phase3 phase4 ## Complete all phases
	@echo "$(GREEN)🎉 All phases completed!$(NC)"
	@echo "$(BLUE)You can now deploy applications using GitOps with FluxCD$(NC)"

.PHONY: down
down: ## Delete k3d cluster
	@echo "$(BLUE)🗑️ Deleting k3d cluster...$(NC)"
	@k3d cluster delete $(CLUSTER_NAME) >/dev/null 2>&1 || echo "$(YELLOW)⚠️  Cluster not found$(NC)"
	@echo "$(GREEN)✅ Cluster deleted$(NC)"
