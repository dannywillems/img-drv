# img-drv.
#
# Every target runs in a PINNED container (see scripts/pins.env), so nothing
# needs to be installed on the host and a laptop runs exactly what CI runs.
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
differential: ## Recompute a real Nix closure's store paths and compare
	./scripts/differential.sh

.PHONY: build
build: python-build ## Build every implementation

.PHONY: test
test: python-test ## Run every test suite

.PHONY: lint
lint: python-lint lint-shell ## Run every linter

.PHONY: python-test
python-test: ## Test the Python implementation
	./scripts/py-check.sh test

.PHONY: python-lint
python-lint: ## Lint and type-check the Python implementation
	./scripts/py-check.sh lint

.PHONY: python-build
python-build: ## Build the Python wheel and sdist
	./scripts/py-build.sh

.PHONY: format
format: ## Format code
	./scripts/py-check.sh format

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf target _build build impl/python/dist impl/python/*.egg-info
	find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

.PHONY: spec-check
spec-check: ## Recompute every golden store path from derivation text alone
	./scripts/py.sh verify docs/spec/examples

.PHONY: aterm-roundtrip
aterm-roundtrip: ## Parse then re-serialize every .drv; must be byte-identical
	./scripts/py.sh roundtrip $(DIR)

.PHONY: corpus
corpus: ## Pull N random nixpkgs packages and verify against them (needs docker)
	./scripts/fetch-corpus.sh $(N)

.PHONY: lint-shell
lint-shell: ## Lint shell scripts
	docker run --rm -v "$$PWD:/w" -w /w \
		koalaman/shellcheck-alpine:stable shellcheck -x scripts/*.sh
