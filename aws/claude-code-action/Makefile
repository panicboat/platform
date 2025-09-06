# Makefile for Claude Code Action

# Default values
ENV ?= develop

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help init plan apply destroy validate fmt check clean

help: ## Show this help message
	@echo "Claude Code Action - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<repository>]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments:"
	@echo "  - develop"
	@echo "  - staging"
	@echo "  - production"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=staging"
	@echo "  make apply ENV=production"

init: ## Initialize Terragrunt
	@echo "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@echo "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@echo "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@echo "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)"
	@echo "$(RED)WARNING: This will destroy all resources!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		echo "$(YELLOW)Cancelled.$(NC)"; \
	fi

validate: ## Validate Terragrunt configuration
	@echo "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@echo "$(YELLOW)Formatting Terraform files...$(NC)"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@echo "$(GREEN)All checks completed for $(ENV)$(NC)"

clean: ## Clean Terragrunt cache
	@echo "$(YELLOW)Cleaning Terragrunt cache...$(NC)"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@echo "$(YELLOW)Showing current state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@echo "$(YELLOW)Showing outputs for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@echo "$(YELLOW)Refreshing state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt refresh
