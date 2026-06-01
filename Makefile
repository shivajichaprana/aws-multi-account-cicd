# Makefile for aws-multi-account-cicd.
# Wraps the same checks CI runs so contributors can gate locally before pushing.
# Recipes operate on both root modules unless a single MODULE is given.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Root modules. Override to target one, e.g. `make validate MODULES=terraform/tooling-account`.
MODULES ?= terraform/tooling-account terraform/target-account

# Pin Terraform to match .github/workflows/ci.yml (env.TERRAFORM_VERSION).
TERRAFORM ?= terraform

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: fmt
fmt: ## Rewrite Terraform files to canonical format.
	@for m in $(MODULES); do echo "== fmt $$m =="; $(TERRAFORM) -chdir=$$m fmt -recursive; done

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting (no writes); fails on drift.
	@for m in $(MODULES); do echo "== fmt-check $$m =="; $(TERRAFORM) -chdir=$$m fmt -check -recursive -diff; done

.PHONY: init
init: ## Backend-less init of each module (safe; no remote state touched).
	@for m in $(MODULES); do echo "== init $$m =="; $(TERRAFORM) -chdir=$$m init -backend=false -input=false; done

.PHONY: validate
validate: init ## Validate each module's configuration.
	@for m in $(MODULES); do echo "== validate $$m =="; $(TERRAFORM) -chdir=$$m validate -no-color; done

.PHONY: lint
lint: lint-yaml lint-shell ## Run all linters (yaml + shell), matching CI.

.PHONY: lint-yaml
lint-yaml: ## yamllint the pipeline specs, appspec, and workflows.
	@yamllint -c .yamllint.yml pipelines/ .github/workflows/ .yamllint.yml

.PHONY: lint-shell
lint-shell: ## shellcheck the operator and pipeline shell scripts.
	@shellcheck --severity=warning $$(find scripts pipelines -type f -name '*.sh' | sort)

.PHONY: plan
plan: ## Terraform plan for one MODULE (requires creds + tfvars). Usage: make plan MODULE=terraform/tooling-account
	@test -n "$(MODULE)" || { echo "set MODULE=terraform/tooling-account|terraform/target-account"; exit 2; }
	$(TERRAFORM) -chdir=$(MODULE) init -input=false
	$(TERRAFORM) -chdir=$(MODULE) plan -input=false

.PHONY: check
check: fmt-check validate lint ## Full local gate: fmt-check + validate + lint.
	@echo "All checks passed."

.PHONY: clean
clean: ## Remove local Terraform working dirs and lock files.
	@find terraform -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@find terraform -type f -name '.terraform.lock.hcl' -delete 2>/dev/null || true
	@echo "Cleaned Terraform working state."
