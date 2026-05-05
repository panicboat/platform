# Makefile for EKS Logs (Loki S3 + Pod Identity)

# Default values
ENV ?= production

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help init plan apply destroy validate fmt check clean

help: ## Show this help message
	@echo "EKS Logs - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments:"
	@echo "  - production"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=production"
	@echo "  make apply ENV=production"

init: ## Initialize Terragrunt
	@printf "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@printf "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@printf "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@printf "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)\n"
	@printf "$(RED)WARNING: This will destroy all resources!$(NC)\n"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		printf "$(YELLOW)Cancelled.$(NC)\n"; \
	fi

validate: ## Validate Terragrunt configuration
	@printf "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@printf "$(YELLOW)Formatting Terraform files...$(NC)\n"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@printf "$(GREEN)All checks completed for $(ENV)$(NC)\n"

clean: ## Clean Terragrunt cache
	@printf "$(YELLOW)Cleaning Terragrunt cache...$(NC)\n"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@printf "$(YELLOW)Showing current state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@printf "$(YELLOW)Showing outputs for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@printf "$(YELLOW)Refreshing state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt refresh
