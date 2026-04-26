# =============================================================================
# Kubernetes Platform Setup for local
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
SHELL := /bin/bash
CLUSTER_NAME ?= k8s-local
ENV ?= local

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
	@printf "$(BLUE)🚀 Kubernetes Platform Setup$(NC)\n"
	@echo ""
	@printf "$(BLUE)Quick Start:$(NC)\n"
	@echo "  make down && make phase1 && make phase2 && make phase3"
	@echo ""
	@printf "$(BLUE)Phase 1: Foundation Setup$(NC)\n"
	@echo "  make phase1              - Complete Phase 1 (cluster, gateway-api, cilium, coredns)"
	@echo "  make cluster-create      - Create k3d cluster"
	@echo "  make gateway-install     - Install Gateway API CRDs"
	@echo "  make cilium-install      - Install Cilium CNI"
	@echo "  make coredns-update      - Fix CoreDNS configuration"
	@echo "  make status              - Check cluster status"
	@echo ""
	@printf "$(BLUE)Phase 2: FluxCD Installation$(NC)\n"
	@echo "  make phase2              - Complete Phase 2 (flux)"
	@echo "  make flux-install        - Install FluxCD"
	@echo "  make flux-status         - Check FluxCD status"
	@echo ""
	@printf "$(BLUE)Phase 3: Infrastructure Components$(NC)\n"
	@echo "  make phase3              - Complete Phase 3 (observability stack)"
	@echo "  - Prometheus, Grafana, Alertmanager"
	@echo "  - Loki, Fluent-bit (logs)"
	@echo "  - Tempo, Beyla, OTel Collector (traces)"
	@echo ""
	@printf "$(BLUE)Phase 4: GitOps Migration (Optional)$(NC)\n"
	@echo "  make phase4              - Enable FluxCD GitOps management"
	@echo ""
	@printf "$(BLUE)Utilities:$(NC)\n"
	@echo "  make hydrate             - Generate manifests from Helmfile"
	@echo "  make down                - Delete k3d cluster"

# =============================================================================
# Phase 0: Hydrate Manifests
# =============================================================================
.PHONY: hydrate-component
hydrate-component: ## Hydrate single component (usage: make hydrate-component COMPONENT=cilium ENV=local)
	@set -euo pipefail; \
	component_dir="components/$(COMPONENT)/$(ENV)"; \
	out_dir="manifests/$(ENV)/$(COMPONENT)"; \
	mkdir -p "$$out_dir"; \
	: > "$$out_dir/manifest.yaml"; \
	if [ -f "$$component_dir/helmfile.yaml" ]; then \
		helmfile -f "$$component_dir/helmfile.yaml" template --include-crds --skip-tests >> "$$out_dir/manifest.yaml"; \
	fi; \
	if [ -d "$$component_dir/kustomization" ]; then \
		echo "---" >> "$$out_dir/manifest.yaml"; \
		kustomize build "$$component_dir/kustomization" >> "$$out_dir/manifest.yaml"; \
	fi; \
	printf "resources:\n  - manifest.yaml\n" > "$$out_dir/kustomization.yaml"; \
	if git ls-files --error-unmatch "$$out_dir/manifest.yaml" >/dev/null 2>&1; then \
		if git diff --quiet -I '^[[:space:]]*(ca\.crt|ca\.key|tls\.crt|tls\.key|caBundle):' -- "$$out_dir/manifest.yaml"; then \
			git checkout -- "$$out_dir/manifest.yaml"; \
		fi; \
	fi

.PHONY: hydrate-index
hydrate-index: ## Regenerate manifests/$(ENV) index and cleanup orphans (usage: make hydrate-index ENV=local)
	@set -euo pipefail; \
	env_dir="manifests/$(ENV)"; \
	mkdir -p "$$env_dir/00-namespaces"; \
	find components -maxdepth 2 -name namespace.yaml | sort | \
		xargs -I{} sh -c 'echo "---"; cat "{}"' > "$$env_dir/00-namespaces/namespaces.yaml"; \
	printf "resources:\n  - namespaces.yaml\n" > "$$env_dir/00-namespaces/kustomization.yaml"; \
	for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null); do \
		name=$$(basename "$$dir"); \
		if [ "$$name" = "00-namespaces" ]; then continue; fi; \
		if [ ! -d "components/$$name/$(ENV)" ]; then \
			rm -rf "$$dir"; \
		fi; \
	done; \
	{ \
		echo "resources:"; \
		echo "  - ./00-namespaces"; \
		for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null | grep -v "/00-namespaces/$$" | sort); do \
			echo "  - ./$$(basename $$dir)"; \
		done; \
	} > "$$env_dir/kustomization.yaml"

.PHONY: hydrate
hydrate: ## Hydrate all components (usage: make hydrate ENV=local)
	@printf "$(BLUE)💧 Hydrating manifests for $(ENV)...$(NC)\n"
	@rm -rf manifests/$(ENV)/*
	@mkdir -p manifests/$(ENV)
	@for component in $$(ls -d components/*/$(ENV) 2>/dev/null | cut -d'/' -f2 | sort -u); do \
		echo "Hydrating $$component..."; \
		$(MAKE) hydrate-component COMPONENT=$$component ENV=$(ENV); \
	done
	@$(MAKE) hydrate-index ENV=$(ENV)
	@printf "$(GREEN)✅ Manifests hydrated$(NC)\n"

# =============================================================================
# Phase 1: Foundation Setup
# =============================================================================
.PHONY: cluster-create
cluster-create: ## Create k3d cluster
	@printf "$(BLUE)🚀 Creating k3d cluster...$(NC)\n"
	@if k3d cluster list 2>/dev/null | grep -q "^$(CLUSTER_NAME)"; then \
		printf "$(YELLOW)⚠️  Cluster already exists$(NC)\n"; \
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
		printf "$(GREEN)✅ Cluster created$(NC)\n"; \
	fi

.PHONY: gateway-install
gateway-install: ## Install Gateway API CRDs
	@printf "$(BLUE)📦 Installing Gateway API CRDs...$(NC)\n"
	@kubectl apply -k components/gateway-api/$(ENV)/kustomization >/dev/null
	@printf "$(BLUE)⏳ Waiting for CRDs to be registered...$(NC)\n"
	@kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=60s >/dev/null
	@printf "$(GREEN)✅ Gateway API CRDs installed$(NC)\n"

.PHONY: cilium-install
cilium-install: ## Install Cilium CNI
	@printf "$(BLUE)📦 Installing Cilium...$(NC)\n"
	@if kubectl get ds cilium -n kube-system >/dev/null 2>&1; then \
		printf "$(YELLOW)⚠️  Cilium already installed$(NC)\n"; \
	else \
		kubectl apply -f manifests/$(ENV)/cilium/manifest.yaml; \
		printf "$(BLUE)⏳ Waiting for Cilium to be ready...$(NC)\n"; \
		kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cilium-operator -n kube-system --timeout=300s >/dev/null; \
		kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s >/dev/null; \
		printf "$(GREEN)✅ Cilium installed$(NC)\n"; \
	fi

.PHONY: coredns-update
coredns-update: ## Fix CoreDNS configuration
	@printf "$(BLUE)⏳ Waiting for k3s initialization...$(NC)\n"
	@kubectl wait --for=condition=ready node --all --timeout=300s >/dev/null
	@sleep 60
	@printf "$(BLUE)🔧 Applying CoreDNS configuration...$(NC)\n"
	@kubectl apply -k components/coredns/$(ENV)/kustomization >/dev/null
	@kubectl rollout restart deployment/coredns -n kube-system >/dev/null
	@kubectl rollout status deployment/coredns -n kube-system --timeout=300s >/dev/null
	@printf "$(BLUE)🧪 Testing DNS resolution...$(NC)\n"
	@if kubectl run dns-test --image=busybox --restart=Never --command -- sh -c "nslookup google.com" >/dev/null 2>&1; then \
		kubectl wait --for=condition=ready pod dns-test --timeout=30s >/dev/null 2>&1; \
		printf "$(GREEN)✅ DNS resolution working$(NC)\n"; \
		kubectl delete pod dns-test >/dev/null 2>&1 || true; \
	else \
		printf "$(RED)❌ DNS resolution failed$(NC)\n"; \
		kubectl delete pod dns-test >/dev/null 2>&1 || true; \
		exit 1; \
	fi

.PHONY: status
status: ## Check cluster status
	@printf "$(BLUE)📊 Cluster Status$(NC)\n"
	@echo ""
	@printf "$(BLUE)Nodes:$(NC)\n"
	@kubectl get nodes
	@echo ""
	@printf "$(BLUE)System Pods:$(NC)\n"
	@kubectl get pods -n kube-system
	@echo ""
	@printf "$(BLUE)Monitoring Pods:$(NC)\n"
	@kubectl get pods -n monitoring 2>/dev/null || echo "  (namespace not created yet)"

# =============================================================================
# Phase 2: FluxCD Installation
# =============================================================================
.PHONY: flux-install
flux-install: ## Install FluxCD
	@printf "$(BLUE)📦 Installing FluxCD...$(NC)\n"
	@if kubectl get namespace flux-system >/dev/null 2>&1; then \
		printf "$(YELLOW)⚠️  FluxCD already installed$(NC)\n"; \
	else \
		flux install --namespace=flux-system --components-extra=image-reflector-controller,image-automation-controller >/dev/null; \
		printf "$(GREEN)✅ FluxCD installed$(NC)\n"; \
	fi
	@printf "$(BLUE)⏳ Waiting for FluxCD to be ready...$(NC)\n"
	@kubectl wait --for=condition=ready pod -l app=source-controller -n flux-system --timeout=300s >/dev/null
	@printf "$(GREEN)✅ FluxCD is ready$(NC)\n"

.PHONY: flux-status
flux-status: ## Check FluxCD status
	@printf "$(BLUE)📊 FluxCD Status$(NC)\n"
	@kubectl get pods -n flux-system
	@echo ""
	@flux get all -A 2>/dev/null || printf "$(YELLOW)No FluxCD resources found$(NC)\n"

# =============================================================================
# Phase 3: Infrastructure Components
# =============================================================================
.PHONY: components-install
components-install: ## Install all infrastructure components
	@printf "$(BLUE)🏗️ Installing infrastructure components...$(NC)\n"
	@printf "$(BLUE)Creating namespaces...$(NC)\n"
	@kubectl apply -f manifests/$(ENV)/00-namespaces/namespaces.yaml
	@sleep 2
	@printf "$(BLUE)Installing Prometheus Operator CRDs...$(NC)\n"
	@kubectl apply --server-side --force-conflicts -f manifests/$(ENV)/prometheus-operator/manifest.yaml >/dev/null 2>&1 || true
	@sleep 15
	@printf "$(BLUE)Installing all components...$(NC)\n"
	@kubectl apply --server-side --force-conflicts -k manifests/$(ENV) >/dev/null
	@printf "$(GREEN)✅ Infrastructure components installed$(NC)\n"
	@echo ""
	@printf "$(BLUE)📊 Access URLs (add to /etc/hosts -> 127.0.0.1):$(NC)\n"
	@echo "  - Grafana:      http://grafana.local      (admin/password)"
	@echo "  - Prometheus:   http://prometheus.local"
	@echo "  - Alertmanager: http://alertmanager.local"
	@echo "  - Hubble UI:    http://hubble.local"
	@echo ""
	@printf "$(GREEN)✅ Components installed$(NC)\n"

# =============================================================================
# Phase 4: GitOps Migration (Optional)
# =============================================================================
.PHONY: gitops-setup
gitops-setup: ## Setup FluxCD GitOps management
	@printf "$(BLUE)🔧 Setting up FluxCD GitOps...$(NC)\n"
	@kubectl apply -k clusters/$(ENV)/flux-system || printf "$(YELLOW)⚠️  Push code to repository first$(NC)\n"
	@printf "$(GREEN)✅ GitOps setup completed$(NC)\n"

.PHONY: gitops-enable
gitops-enable: ## Enable GitOps management for all components
	@printf "$(BLUE)🔄 Enabling GitOps for all components...$(NC)\n"
	@kubectl apply -k clusters/$(ENV) >/dev/null || printf "$(YELLOW)⚠️  GitOps migration failed$(NC)\n"
	@printf "$(GREEN)✅ GitOps enabled$(NC)\n"

.PHONY: gitops-status
gitops-status: ## Check GitOps status
	@printf "$(BLUE)📊 GitOps Status$(NC)\n"
	@flux get sources git -A || printf "$(YELLOW)No Git sources found$(NC)\n"
	@echo ""
	@flux get kustomizations -A || printf "$(YELLOW)No Kustomizations found$(NC)\n"

# =============================================================================
# Complete Phases
# =============================================================================
.PHONY: phase1
phase1: cluster-create gateway-install cilium-install coredns-update status ## Complete Phase 1
	@printf "$(GREEN)🎉 Phase 1 Complete!$(NC)\n"

.PHONY: phase2
phase2: flux-install flux-status ## Complete Phase 2
	@printf "$(GREEN)🎉 Phase 2 Complete!$(NC)\n"

.PHONY: phase3
phase3: components-install ## Complete Phase 3
	@printf "$(GREEN)🎉 Phase 3 Complete!$(NC)\n"

.PHONY: phase4
phase4: gitops-setup gitops-enable gitops-status ## Complete Phase 4
	@printf "$(GREEN)🎉 Phase 4 Complete!$(NC)\n"
	@printf "$(BLUE)🔄 Full GitOps management enabled$(NC)\n"

# =============================================================================
# Complete All Phases
# =============================================================================
.PHONY: up
up: hydrate phase1 phase2 phase3 phase4 ## Complete all phases (excluding phase4)
	@printf "$(GREEN)🎉 All phases completed!$(NC)\n"

.PHONY: down
down: ## Delete k3d cluster
	@printf "$(BLUE)🗑️  Deleting k3d cluster...$(NC)\n"
	@k3d cluster delete $(CLUSTER_NAME) >/dev/null 2>&1 || printf "$(YELLOW)⚠️  Cluster not found$(NC)\n"
	@printf "$(GREEN)✅ Cluster deleted$(NC)\n"
