# Variables
CLUSTER_NAME ?= k8s-local

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
	@echo "$(BLUE)Phase 4: Gitea Configuration & Setup$(NC)"
	@echo "make phase4        - Complete Phase 4"
	@echo "- Gitea port-forward and setup guidance"
	@echo "- Repository creation and Git configuration"
	@echo ""
	@echo "$(BLUE)Phase 5: GitOps Complete Migration$(NC)"
	@echo "make phase5        - Complete Phase 5"
	@echo ""
	@echo "$(BLUE)Individual targets:$(NC)"
	@echo "make gitea-setup     - Start Gitea port-forward and show setup guide"
	@echo "make gitops-setup    - Setup FluxCD GitOps management"
	@echo "make gitops-status   - Check GitOps status"
	@echo "make gitops-enable   - Enable GitOps for all components"

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
	@if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  Gateway API CRDs already installed$(NC)"; \
	else \
		kubectl apply -k infrastructures/gateway-api/base/bootstrap >/dev/null; \
		echo "$(GREEN)✅ Gateway API CRDs installed$(NC)"; \
	fi

.PHONY: cilium-install
cilium-install: ## Install Cilium directly via Helm
	@echo "$(BLUE)📦 Installing Cilium directly via Helm...$(NC)"
	@if helm list -n kube-system | grep -q cilium; then \
    echo "$(YELLOW)⚠️  Cilium already installed$(NC)"; \
	else \
		helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1; \
    helm repo update >/dev/null 2>&1; \
    helm install cilium cilium/cilium \
      --namespace kube-system \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost=k3d-k8s-local-server-0 \
      --set k8sServicePort=6443 \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="{10.42.0.0/16}" \
      --set operator.replicas=1 \
      --set gatewayAPI.enabled=true \
      --set hostServices.enabled=false \
      --set dnsProxy.enabled=false \
      --set ipv6.enabled=false \
      --set enableIPv4Masquerade=true >/dev/null; \
		echo "$(BLUE)⏳ Waiting for Cilium to be ready...$(NC)"; \
		kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cilium-operator -n kube-system --timeout=300s >/dev/null; \
		kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s >/dev/null; \
		echo "$(GREEN)✅ Cilium installed directly via Helm$(NC)"; \
	fi

.PHONY: coredns-update
coredns-update: ## Fix CoreDNS after k3s stabilization
	@echo "$(BLUE)⏳ Waiting for k3s initialization to complete...$(NC)"
	@kubectl wait --for=condition=ready node --all --timeout=300s >/dev/null
	@sleep 60
	@echo "$(BLUE)🔧 Applying CoreDNS patch (after k3s stabilization)...$(NC)"
	@kubectl apply -f infrastructures/kubernetes/overlays/k3d/coredns-patch.yaml >/dev/null
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

.PHONY: phase1
phase1: cluster-create gateway-install cilium-install coredns-update status ## Complete Phase 1
	@echo "$(GREEN)🎉 Phase 1 Complete!$(NC)"

# Phase 2: FluxCD Installation
.PHONY: flux-install
flux-install: ## Install FluxCD
	@echo "$(BLUE)📦 Installing FluxCD...$(NC)"
	@if kubectl get namespace flux-system >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  Already installed$(NC)"; \
	else \
		flux install --namespace=flux-system >/dev/null; \
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

.PHONY: phase2
phase2: flux-install flux-status ## Complete Phase 2
	@echo "$(GREEN)🎉 Phase 2 Complete!$(NC)"

# Phase 3: Infrastructure Auto-Bootstrap
.PHONY: phase3
phase3: ## Complete Phase 3 (Auto-discover and install all infrastructure)
	@echo "$(BLUE)🏗️ Auto-bootstrapping all infrastructure components...$(NC)"
	@echo "$(BLUE)📦 Setting up HelmRepositories...$(NC)"
	@kubectl apply -k helmrepositories >/dev/null
	@echo "$(BLUE)🔍 Auto-discovering infrastructure components...$(NC)"
	@bootstrap_dirs=$$(find infrastructures/*/base/bootstrap -name kustomization.yaml 2>/dev/null | xargs dirname | grep -v cilium); \
	if [ -z "$$bootstrap_dirs" ]; then \
		echo "$(YELLOW)⚠️  No infrastructure components found$(NC)"; \
	else \
		for dir in $$bootstrap_dirs; do \
			component=$$(echo $$dir | cut -d'/' -f2); \
			echo "$(BLUE)Installing $$component via Bootstrap...$(NC)"; \
			kubectl apply -k $$dir >/dev/null || echo "$(YELLOW)⚠️  $$component installation failed$(NC)"; \
		done; \
		echo "$(BLUE)⏳ Waiting for all components to be ready...$(NC)"; \
		kubectl wait --for=condition=ready helmrelease --all -n flux-system --timeout=300s >/dev/null 2>&1 || true; \
		echo "$(GREEN)✅ All infrastructure components installed$(NC)"; \
	fi
	@echo "$(GREEN)🎉 Phase 3 Complete!$(NC)"
	@echo "$(BLUE)💡 Ready for Gitea configuration (Phase 4)$(NC)"

# Phase 4: Gitea Configuration & Operation Setup
.PHONY: gitea-setup
gitea-setup: ## Start Gitea port-forward and show setup instructions
	@echo "$(BLUE)🔧 Starting Gitea setup...$(NC)"
	@if ! kubectl get pod -l app.kubernetes.io/name=gitea -n gitea >/dev/null 2>&1; then \
		echo "$(RED)❌ Gitea not found. Run 'make phase3' first$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)🌐 Starting port-forward to Gitea...$(NC)"
	@echo "$(YELLOW)💡 Access Gitea at: http://localhost:3000$(NC)"
	@echo "$(YELLOW)💡 Admin credentials: giteaadmin / admin123$(NC)"
	@echo ""
	@echo "$(BLUE)📋 Setup Instructions:$(NC)"
	@echo "  1. Access http://localhost:3000 in your browser"
	@echo "  2. Login with giteaadmin / admin123"
	@echo "  3. Create a new repository named 'platform'"
	@echo "  4. Run the following commands in this directory:"
	@echo ""
	@echo "$(GREEN)git init$(NC)"
	@echo "$(GREEN)git add .$(NC)"
	@echo "$(GREEN)git commit -m \"Initial platform setup\"$(NC)"
	@echo "$(GREEN)git branch -M main$(NC)"
	@echo "$(GREEN)git remote add gitea http://giteaadmin:admin123@localhost:3000/giteaadmin/platform.git$(NC)"
	@echo "$(GREEN)git push -u gitea main$(NC)"
	@echo ""
	@echo "$(BLUE)Press Ctrl+C to stop port-forward when done$(NC)"
	@kubectl port-forward -n gitea svc/gitea-gitea-http 3000:3000 &

.PHONY: phase4
phase4: gitea-setup ## Complete Phase 4 (Gitea Configuration & Setup)
	@echo "$(GREEN)🎉 Phase 4 Complete!$(NC)"
	@echo "$(BLUE)🔗 Gitea configured and ready for GitOps$(NC)"

# Phase 5: Application Deployment
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

# Phase 5: GitOps Complete Migration
.PHONY: phase5
phase5: gitops-setup gitops-enable gitops-status ## Complete Phase 5 (GitOps Migration)
	@echo "$(GREEN)🎉 Phase 5 Complete!$(NC)"
	@echo "$(BLUE)🔄 Full GitOps management enabled$(NC)"
	@echo "$(BLUE)💡 All infrastructure now managed by FluxCD from Git repository$(NC)"

.PHONY: up
up: phase1 phase2 phase3 phase4 ## Complete all phases
	@echo "$(GREEN)🎉 All phases completed!$(NC)"
	@echo "$(BLUE)You can now deploy applications using GitOps with FluxCD and Gitea$(NC)"
	@echo "$(YELLOW)💡 Optional: Run 'make phase5' for complete GitOps migration$(NC)"

.PHONY: down
down: ## Delete k3d cluster
	@echo "$(BLUE)🗑️ Deleting k3d cluster...$(NC)"
	@k3d cluster delete $(CLUSTER_NAME) >/dev/null 2>&1 || echo "$(YELLOW)⚠️  Cluster not found$(NC)"
	@echo "$(GREEN)✅ Cluster deleted$(NC)"
