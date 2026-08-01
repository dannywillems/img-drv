# img-drv. Nothing is implemented yet; see PLAN.md.
#
# Targets are declared ahead of the code on purpose: the conformance target is
# the point of the project, and naming it now keeps the phases honest.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Ask for help!
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; \
		{printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

.PHONY: conformance
conformance: ## Assert every eDSL emits byte-identical IR (the whole point)
	@echo "not implemented: see PLAN.md phase 2"
	@exit 1

.PHONY: differential
differential: ## Compare our .drv against nix-instantiate's, byte for byte
	@echo "not implemented: see PLAN.md phase 1"
	@exit 1

.PHONY: build
build: ## Build every implementation

.PHONY: test
test: ## Run every test suite

.PHONY: check-format
check-format: ## Check formatting

.PHONY: format
format: ## Format code

.PHONY: lint
lint: ## Run linters

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf target _build
