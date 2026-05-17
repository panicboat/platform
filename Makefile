# Makefile (repo root) - EKS production teardown entry points
#
# Usage:
#   make eks-teardown ENV=production           # full teardown
#   make eks-teardown-k8s ENV=production       # k8s cleanup only
#   make eks-teardown-aws ENV=production       # terragrunt destroy only
#   make eks-teardown-verify ENV=production    # orphan verify only
#
#   DRY_RUN=1 make eks-teardown ENV=production # echo commands without exec
#
# Recreate (= cluster bootstrap) は manual runbook で実行する:
#   docs/runbooks/eks-production-recreate.md

ENV ?=

.PHONY: help eks-teardown eks-teardown-k8s eks-teardown-aws eks-teardown-verify

help:
	@echo "EKS Lifecycle commands:"
	@echo ""
	@echo "  make eks-teardown ENV=production"
	@echo ""
	@echo "  Recreate: docs/runbooks/eks-production-recreate.md"
	@echo ""
	@echo "  ENV=$(ENV)"
	@echo "  DRY_RUN=$(DRY_RUN) (= '1' for dry-run, anything else for live)"

eks-teardown: eks-teardown-k8s eks-teardown-aws eks-teardown-verify
	@printf "\033[0;32m[OK]\033[0m teardown complete\n"

eks-teardown-k8s:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/10-k8s-cleanup.sh

eks-teardown-aws:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/30-destroy-stacks.sh

eks-teardown-verify:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/40-orphan-verify.sh
