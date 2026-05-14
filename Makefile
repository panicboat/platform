# Makefile (repo root) - EKS production lifecycle entry points
#
# Usage:
#   make eks-teardown ENV=production           # full teardown
#   make eks-teardown-k8s ENV=production       # k8s cleanup only
#   make eks-teardown-aws ENV=production       # terragrunt destroy only
#   make eks-teardown-verify ENV=production    # orphan verify only
#   make eks-recreate ENV=production           # full recreate
#   make eks-recreate-aws ENV=production       # terragrunt apply only
#   make eks-recreate-flux ENV=production      # flux bootstrap only
#   make eks-recreate-watch ENV=production     # reconcile watch only
#
#   DRY_RUN=1 make eks-teardown ENV=production # echo commands without exec
#
# See docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

ENV ?=

.PHONY: help eks-teardown eks-teardown-k8s eks-teardown-aws eks-teardown-verify
.PHONY: eks-recreate eks-recreate-aws eks-recreate-flux eks-recreate-watch

help:
	@echo "EKS Lifecycle commands:"
	@echo ""
	@echo "  make eks-teardown ENV=production"
	@echo "  make eks-recreate ENV=production"
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

eks-recreate: eks-recreate-aws eks-recreate-flux eks-recreate-watch
	@printf "\033[0;32m[OK]\033[0m recreate complete\n"

eks-recreate-aws:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/50-apply-stacks.sh

eks-recreate-flux:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/60-flux-bootstrap.sh

eks-recreate-watch:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/70-reconcile-watch.sh
