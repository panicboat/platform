# Argo CD Setup Guide for minikube

**English** | [日本語版 (Japanese)](README.ja.md)

This document explains how to set up Argo CD in a minikube environment to manage Helm charts using GitOps.

## Prerequisites

- minikube installed
- kubectl installed
- Git repository with the following structure:

```
kubernetes-manifests/
├── applications/
│   └── minikube/
│       ├── argo-cd.yaml
│       └── ingress-nginx.yaml
├── argo-cd/
│   ├── Chart.yaml
│   └── values/
│       ├── common.yaml
│       └── minikube.yaml
└── ingress-nginx/
    ├── Chart.yaml
    └── values/
        ├── common.yaml
        └── minikube.yaml
```

## Setup Instructions

### 1. Start minikube

```bash
# Start minikube
minikube start
```

**Note**: We don't use minikube's ingress addon since we manage our own ingress-nginx through Helm charts.

### 2. Initial Argo CD Installation

```bash
# Create Argo CD namespace
kubectl create namespace argocd

# Install Argo CD base version (using official manifests)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD server to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

### 3. Initial Access to Argo CD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward for access (run in separate terminal)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access `https://localhost:8080` in your browser and log in with:
- Username: `admin`
- Password: password obtained above

### 4. Start GitOps Management

This is the crucial step where we make Argo CD manage itself through GitOps.

```bash
# Deploy Argo CD Application (self-management)
kubectl apply -f applications/minikube/argo-cd.yaml

# Deploy ingress-nginx Application
kubectl apply -f applications/minikube/ingress-nginx.yaml
```

### 5. Verify Setup

```bash
# Check Applications status
kubectl get applications -n argocd

# Expected output:
# NAME            SYNC STATUS   HEALTH STATUS   AGE
# argo-cd         Synced        Healthy         2m
# ingress-nginx   Synced        Healthy         1m

# Verify all pods are running
kubectl get pods -n argocd
kubectl get pods -n ingress-nginx
```

### 6. Access via NodePort

In minikube environment, we use NodePort to access Argo CD:

```bash
# Get minikube IP address
minikube ip

# Access using the IP address
# https://<minikube-ip>:30443
```

Or use minikube service command:

```bash
# Opens browser automatically
minikube service argocd-server -n argocd
```

## Key Concepts

### Why Staged Setup is Required

This solves the "chicken and egg problem":

1. **Initial State**: No Argo CD exists
2. **Manual Install**: Install basic Argo CD
3. **GitOps Migration**: Configure Argo CD to manage itself
4. **Full Automation**: All applications managed by GitOps

```
Initial State:
┌─────────────────┐
│ Manual Install  │  ← Basic Argo CD configuration
│ Argo CD         │
└─────────────────┘

↓ Apply applications/minikube/argo-cd.yaml

Final State:
┌─────────────────┐
│ Helm-managed    │  ← Your custom configuration
│ Argo CD         │  ← Managed by GitOps
└─────────────────┘
┌─────────────────┐
│ ingress-nginx   │  ← Managed by Argo CD
└─────────────────┘
```

### Why Not Use minikube Addons

- **Consistency**: Same management approach across all environments (develop/staging/production)
- **Version Control**: Explicit version management through Helm charts
- **Customization**: Detailed configuration capabilities
- **GitOps**: Everything managed through Git

## Troubleshooting

### Applications Not Syncing

```bash
# Check Application details
kubectl describe application argo-cd -n argocd
kubectl describe application ingress-nginx -n argocd

# Check Argo CD server logs
kubectl logs -n argocd deployment/argocd-server
```

### Manual Sync

```bash
# Sync via CLI
kubectl patch application argo-cd -n argocd --type merge -p '{"operation":{"sync":{}}}'

# Or click "SYNC" button in Web UI
```

### Forgot Password

```bash
# Retrieve admin password again
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Next Steps

1. **Add More Applications**: Add new Helm charts to repository
2. **Environment Switch**: Deploy to develop/staging/production environments
3. **Monitoring Setup**: Add Prometheus/Grafana
4. **Security Enhancement**: Configure RBAC, OIDC

## References

- [Argo CD Official Documentation](https://argo-cd.readthedocs.io/)
- [Argo CD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [minikube Official Documentation](https://minikube.sigs.k8s.io/docs/)
