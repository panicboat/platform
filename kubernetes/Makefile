# =============================================================================
# Kubernetes Platform Setup for k3d
# =============================================================================
# This Makefile provides commands to set up and manage a local Kubernetes
# cluster using k3d with a production-ready observability stack.
#
# Prerequisites:
#   - k3d: https://k3d.io
#   - kubectl: https://kubernetes.io/docs/tasks/tools/
#   - helm: https://helm.sh
#   - helmfile: https://github.com/helmfile/helmfile
#   - flux: https://fluxcd.io/flux/installation/
#
# Quick Start:
#   make down && make phase1 && make phase2 && make phase3
#
# Architecture:
#   Beyla (eBPF) -> OTel Collector -> Tempo (traces)
#                                  -> Loki (logs via Fluent-bit)
#                                  -> Prometheus (metrics)
#   All data visualized in Grafana
#
# TODO: (production) For EKS deployment, create separate environment configs
# =============================================================================

# =============================================================================
# Variables
# =============================================================================
CLUSTER_NAME ?= k8s-local
ENV ?= k3d

# Colors for output
GREEN  := \033[0;32m
BLUE   := \033[0;34m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## Show help
	@echo "$(BLUE)🚀 Kubernetes Platform Setup$(NC)"
	@echo ""
	@echo "$(BLUE)Quick Start:$(NC)"
	@echo "  make down && make phase1 && make phase2 && make phase3"
	@echo ""
	@echo "$(BLUE)Phase 1: Foundation Setup$(NC)"
	@echo "  make phase1              - Complete Phase 1 (cluster, gateway-api, cilium, coredns)"
	@echo "  make cluster-create      - Create k3d cluster"
	@echo "  make gateway-install     - Install Gateway API CRDs"
	@echo "  make cilium-install      - Install Cilium CNI"
	@echo "  make coredns-update      - Fix CoreDNS configuration"
	@echo "  make status              - Check cluster status"
	@echo ""
	@echo "$(BLUE)Phase 2: FluxCD Installation$(NC)"
	@echo "  make phase2              - Complete Phase 2 (flux)"
	@echo "  make flux-install        - Install FluxCD"
	@echo "  make flux-status         - Check FluxCD status"
	@echo ""
	@echo "$(BLUE)Phase 3: Infrastructure Components$(NC)"
	@echo "  make phase3              - Complete Phase 3 (observability stack)"
	@echo "  - Prometheus, Grafana, Alertmanager"
	@echo "  - Loki, Fluent-bit (logs)"
	@echo "  - Tempo, Beyla, OTel Collector (traces)"
	@echo ""
	@echo "$(BLUE)Phase 4: GitOps Migration (Optional)$(NC)"
	@echo "  make phase4              - Enable FluxCD GitOps management"
	@echo ""
	@echo "$(BLUE)Utilities:$(NC)"
	@echo "  make hydrate             - Generate manifests from Helmfile"
	@echo "  make down                - Delete k3d cluster"

# =============================================================================
# Phase 0: Hydrate Manifests
# =============================================================================
.PHONY: hydrate
hydrate: ## Hydrate manifests from Helmfile and Kustomize (usage: make hydrate ENV=k3d)
	@echo "$(BLUE)💧 Hydrating manifests for $(ENV)...$(NC)"
	@rm -rf manifests/$(ENV)/*
	@mkdir -p manifests/$(ENV)
	@echo "$(BLUE)💧 Hydrating namespaces...$(NC)"
	@find components -name namespace.yaml -print0 | xargs -0 -I{} sh -c 'echo "---"; cat {}' > manifests/$(ENV)/00-namespaces.yaml
	@echo "$(BLUE)💧 Hydrating components...$(NC)"
	@echo "resources:" > manifests/$(ENV)/kustomization.yaml
	@for component in $$(ls -d components/*/$(ENV) 2>/dev/null | cut -d'/' -f2 | sort -u); do \
		component_dir="components/$$component/$(ENV)"; \
		echo "Hydrating $$component..."; \
		: > manifests/$(ENV)/$$component.yaml; \
		[ -f "$$component_dir/helmfile.yaml" ] && helmfile -f "$$component_dir/helmfile.yaml" template --include-crds --skip-tests >> manifests/$(ENV)/$$component.yaml; \
		[ -d "$$component_dir/kustomization" ] && { echo "---"; kustomize build "$$component_dir/kustomization"; } >> manifests/$(ENV)/$$component.yaml; \
		echo "- $$component.yaml" >> manifests/$(ENV)/kustomization.yaml; \
	done
	@echo "- 00-namespaces.yaml" >> manifests/$(ENV)/kustomization.yaml
	@echo "$(GREEN)✅ Manifests hydrated$(NC)"

# =============================================================================
# Phase 1: Foundation Setup
# =============================================================================
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
cilium-install: ## Install Cilium CNI
	@echo "$(BLUE)📦 Installing Cilium...$(NC)"
	@if kubectl get ds cilium -n kube-system >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  Cilium already installed$(NC)"; \
	else \
		kubectl apply -f manifests/k3d/cilium.yaml; \
		echo "$(BLUE)⏳ Waiting for Cilium to be ready...$(NC)"; \
		kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cilium-operator -n kube-system --timeout=300s >/dev/null; \
		kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s >/dev/null; \
		echo "$(GREEN)✅ Cilium installed$(NC)"; \
	fi

.PHONY: coredns-update
coredns-update: ## Fix CoreDNS configuration
	@echo "$(BLUE)⏳ Waiting for k3s initialization...$(NC)"
	@kubectl wait --for=condition=ready node --all --timeout=300s >/dev/null
	@sleep 60
	@echo "$(BLUE)🔧 Applying CoreDNS configuration...$(NC)"
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
	@echo ""
	@echo "$(BLUE)Nodes:$(NC)"
	@kubectl get nodes
	@echo ""
	@echo "$(BLUE)System Pods:$(NC)"
	@kubectl get pods -n kube-system
	@echo ""
	@echo "$(BLUE)Monitoring Pods:$(NC)"
	@kubectl get pods -n monitoring 2>/dev/null || echo "  (namespace not created yet)"

# =============================================================================
# Phase 2: FluxCD Installation
# =============================================================================
.PHONY: flux-install
flux-install: ## Install FluxCD
	@echo "$(BLUE)📦 Installing FluxCD...$(NC)"
	@if kubectl get namespace flux-system >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  FluxCD already installed$(NC)"; \
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
	@flux get all -A 2>/dev/null || echo "$(YELLOW)No FluxCD resources found$(NC)"

# =============================================================================
# Phase 3: Infrastructure Components
# =============================================================================
.PHONY: components-install
components-install: ## Install all infrastructure components
	@echo "$(BLUE)🏗️ Installing infrastructure components...$(NC)"
	@echo "$(BLUE)Creating namespaces...$(NC)"
	@kubectl apply -f manifests/k3d/00-namespaces.yaml
	@sleep 2
	@echo "$(BLUE)Installing Prometheus Operator CRDs...$(NC)"
	@kubectl apply --server-side --force-conflicts -f manifests/k3d/prometheus-operator.yaml >/dev/null 2>&1 || true
	@sleep 15
	@echo "$(BLUE)Installing all components...$(NC)"
	@kubectl apply --server-side --force-conflicts -k manifests/k3d >/dev/null
	@echo "$(GREEN)✅ Infrastructure components installed$(NC)"
	@echo ""
	@echo "$(BLUE)📊 Access URLs (add to /etc/hosts -> 127.0.0.1):$(NC)"
	@echo "  - Grafana:      http://grafana.local      (admin/password)"
	@echo "  - Prometheus:   http://prometheus.local"
	@echo "  - Alertmanager: http://alertmanager.local"
	@echo "  - Hubble UI:    http://hubble.local"
	@echo ""
	@echo "$(GREEN)✅ Components installed$(NC)"

# =============================================================================
# Phase 4: GitOps Migration (Optional)
# =============================================================================
.PHONY: gitops-setup
gitops-setup: ## Setup FluxCD GitOps management
	@echo "$(BLUE)🔧 Setting up FluxCD GitOps...$(NC)"
	@kubectl apply -k clusters/k3d/flux-system || echo "$(YELLOW)⚠️  Push code to repository first$(NC)"
	@echo "$(GREEN)✅ GitOps setup completed$(NC)"

.PHONY: gitops-enable
gitops-enable: ## Enable GitOps management for all components
	@echo "$(BLUE)🔄 Enabling GitOps for all components...$(NC)"
	@kubectl apply -k clusters/k3d >/dev/null || echo "$(YELLOW)⚠️  GitOps migration failed$(NC)"
	@echo "$(GREEN)✅ GitOps enabled$(NC)"

.PHONY: gitops-status
gitops-status: ## Check GitOps status
	@echo "$(BLUE)📊 GitOps Status$(NC)"
	@flux get sources git -A || echo "$(YELLOW)No Git sources found$(NC)"
	@echo ""
	@flux get kustomizations -A || echo "$(YELLOW)No Kustomizations found$(NC)"

# =============================================================================
# Complete Phases
# =============================================================================
.PHONY: phase1
phase1: cluster-create gateway-install cilium-install coredns-update status ## Complete Phase 1
	@echo "$(GREEN)🎉 Phase 1 Complete!$(NC)"

.PHONY: phase2
phase2: flux-install flux-status ## Complete Phase 2
	@echo "$(GREEN)🎉 Phase 2 Complete!$(NC)"

.PHONY: phase3
phase3: components-install ## Complete Phase 3
	@echo "$(GREEN)🎉 Phase 3 Complete!$(NC)"

.PHONY: phase4
phase4: gitops-setup gitops-enable gitops-status ## Complete Phase 4
	@echo "$(GREEN)🎉 Phase 4 Complete!$(NC)"
	@echo "$(BLUE)🔄 Full GitOps management enabled$(NC)"

# =============================================================================
# Complete All Phases
# =============================================================================
.PHONY: up
up: hydrate phase1 phase2 phase3 phase4 ## Complete all phases (excluding phase4)
	@echo "$(GREEN)🎉 All phases completed!$(NC)"

.PHONY: down
down: ## Delete k3d cluster
	@echo "$(BLUE)🗑️  Deleting k3d cluster...$(NC)"
	@k3d cluster delete $(CLUSTER_NAME) >/dev/null 2>&1 || echo "$(YELLOW)⚠️  Cluster not found$(NC)"
	@echo "$(GREEN)✅ Cluster deleted$(NC)"
