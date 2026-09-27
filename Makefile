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
