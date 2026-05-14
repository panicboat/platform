#!/usr/bin/env bash
# 70-reconcile-watch.sh - Wait for all HelmReleases to become Ready,
# grouped by roadmap Phase 1-5.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd kubectl flux

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  error "Cluster not reachable. Run make eks-recreate-aws ENV=${ENV} first."
  exit 1
fi

use_admin_creds

# Helper: wait for given HelmReleases (= ns/name pairs) to be Ready.
wait_helmreleases() {
  local timeout="$1"; shift
  local hr
  for hr in "$@"; do
    local ns="${hr%%/*}"
    local name="${hr#*/}"
    info "Waiting HelmRelease ${ns}/${name} (timeout ${timeout}) ..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
      printf "${YELLOW}[DRY-RUN]${NC} kubectl wait helmrelease/%s -n %s --for=condition=Ready --timeout=%s\n" \
        "$name" "$ns" "$timeout"
      continue
    fi
    if ! kubectl wait "helmrelease/${name}" -n "$ns" --for=condition=Ready --timeout="$timeout" 2>/dev/null; then
      error "HelmRelease ${ns}/${name} not Ready in ${timeout}. Inspect:
    flux logs -n ${ns}
    kubectl describe helmrelease ${name} -n ${ns}"
      exit 1
    fi
  done
}

# HelmRelease list は kubernetes/components/*/production/helmfile.yaml の
# release name + namespace から復元 (= 2026-05-15 時点)。Step 3 で
# 実 cluster の `kubectl get helmreleases -A` と必ず照合する。

info "Phase 1: foundation addons"
wait_helmreleases 600s \
  kube-system/cilium \
  kube-system/aws-load-balancer-controller \
  external-dns/external-dns \
  external-secrets/external-secrets \
  kube-system/metrics-server \
  keda/keda

info "Phase 2: Karpenter"
wait_helmreleases 600s karpenter/karpenter

info "Phase 3: observability (= OTel operator -> stack -> collectors)"
wait_helmreleases 600s opentelemetry-operator-system/opentelemetry-operator
wait_helmreleases 1200s \
  monitoring/kube-prometheus-stack \
  monitoring/mimir-distributed \
  monitoring/loki \
  monitoring/tempo \
  monitoring/opentelemetry-collector \
  monitoring/beyla

info "Phase 4: cert-manager + reloader"
wait_helmreleases 600s \
  cert-manager/cert-manager \
  reloader/reloader

info "Phase 5: oauth2-proxy (= 4 release per IngressGroup)"
wait_helmreleases 600s \
  oauth2-proxy/oauth2-proxy-grafana \
  oauth2-proxy/oauth2-proxy-hubble \
  oauth2-proxy/oauth2-proxy-alertmanager \
  oauth2-proxy/oauth2-proxy-prometheus

info "Status summary:"
run kubectl get helmreleases -A
run kubectl get kustomizations -A

# Final check: any Failed?
if [ "${DRY_RUN:-0}" != "1" ]; then
  if kubectl get helmreleases -A -o json | \
     jq -e '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False"))' >/dev/null 2>&1; then
    error "Some HelmReleases are in Failed state. Inspect with: flux get helmreleases -A"
    exit 1
  fi
fi

ok "All HelmReleases Ready. Recreate complete."
